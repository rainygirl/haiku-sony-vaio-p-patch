#!/bin/bash
#
# Build a 32-bit (x86_gcc2h) RenkuOS anyboot ISO patched for the Sony VAIO P
# (VGN-P70H_G) -- see AGENTS.md next to this script for what these patches are
# and why they exist.
#
# Source: RenkuOS (https://github.com/RenkuOS/Source), at the commit its
# published nightly image was built from.
#
# Why this builds 32-bit when the RenkuOS nightly is x86_64 only: the VAIO P's
# Atom Z520 has no long mode. CPUID 0x80000001 EDX reads 0x00100000 on this
# machine -- NX and nothing else, bit 29 (LM) clear -- so an x86_64 image cannot
# run on it at all. RenkuOS dropped x86 from its nightly matrix only because the
# pure-x86 build-packages snapshot 404s; its own workflow notes that the
# x86_gcc2h hybrid snapshot upstream publishes is the way back, and that is the
# target built here.
#
# This script is meant to run INSIDE a Linux (Ubuntu/Debian, amd64)
# environment -- building the legacy x86_gcc2 cross-compiler requires -m32 host
# support, which neither macOS nor arm64 Linux provide. On macOS, use
# docker-build-vaio-p-iso.sh instead, which sets up an amd64 Linux container and
# runs this script inside it.
#
# Usage:
#   ./build-vaio-p-iso.sh [work-dir] [output-iso-path]
#
#   work-dir          Directory to clone/build in. Reused across runs if it
#                      already has renku/buildtools checked out (default:
#                      ./vaio-p-work next to this script).
#   output-iso-path    Where to copy the finished ISO (default:
#                      ./renku-vaio-p.iso in the current directory).
#
# Environment variables:
#   SKIP_CROSS_TOOLS=1   Skip (re)building the cross-compiler if
#                        work-dir/generated.x86_gcc2h/cross-tools-x86_gcc2
#                        and .../cross-tools-x86 already exist. Useful for
#                        quick rebuilds after only touching a patch, since
#                        the cross-tools build alone takes ~1-1.5 hours.
#                        Off by default: always rebuilt, since it's the
#                        step most likely to silently go stale/wrong if
#                        skipped by mistake.
#   RENKU_REF            Branch/tag/commit of RenkuOS/Source to build.
#                        Default: the commit the current nightly release was
#                        built from, read from its release notes (see
#                        resolve_nightly_commit below for why not the
#                        "nightly" tag). Falls back to the commit the patch
#                        was last verified against if that lookup fails.
#   DISTRO_COMPATIBILITY configure --distro-compatibility. Default: "default",
#                        as the RenkuOS nightly uses. "default" ships no
#                        trademarked artwork; restore-haiku-logo.sh puts the
#                        desktop logo back on an installed system.
#   IMAGE_LABEL          HAIKU_IMAGE_LABEL. Default: "RenkuOS", as the nightly.
#   JOBS                 Parallelism for configure/jam. Default: nproc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${1:-$SCRIPT_DIR/vaio-p-work}"
OUTPUT_ISO="${2:-$PWD/renku-vaio-p.iso}"
JOBS="${JOBS:-$(nproc)}"
DISTRO_COMPATIBILITY="${DISTRO_COMPATIBILITY:-default}"
IMAGE_LABEL="${IMAGE_LABEL:-RenkuOS}"

RENKU_REPO="https://github.com/RenkuOS/Source.git"
RENKU_API="https://api.github.com/repos/RenkuOS/Source"
# The RenkuOS commit vaio-p-patches.diff was last regenerated from and
# verified against (plain apply and reverse apply both clean). Used only when
# the nightly cannot be looked up; bump it when the diff is regenerated.
VERIFIED_RENKU_REF="f04d7eb54afa6132ca81d9be3eb3017de9b573d8"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Linux" ]; then
	die "this script must run on Linux (the legacy x86_gcc2 cross-compiler" \
		"cannot be built on macOS — use docker-build-vaio-p-iso.sh instead)"
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---------------------------------------------------------------------------
log "Checking build dependencies"
# ---------------------------------------------------------------------------
REQUIRED_CMDS=(setfattr getfattr git wget gcc g++ make bison flex gawk nasm autoconf automake
	libtool xorriso zip unzip)
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
	command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -gt 0 ] || ! dpkg -l gcc-multilib >/dev/null 2>&1; then
	log "Installing missing packages via apt"
	# A stock container runs as root and has no sudo at all.
	SUDO=""
	[ "$(id -u)" -eq 0 ] || SUDO="sudo"
	export DEBIAN_FRONTEND=noninteractive
	$SUDO dpkg --add-architecture i386
	$SUDO apt-get update -qq
	$SUDO apt-get install -y -qq \
		build-essential gcc-multilib g++-multilib \
		bison flex gawk texinfo nasm git wget \
		autoconf automake libtool python3 zip unzip xorriso \
		zlib1g-dev zlib1g-dev:i386 libzstd-dev liblzma-dev libncurses-dev
fi

# ---------------------------------------------------------------------------
log "Fetching RenkuOS source"
# ---------------------------------------------------------------------------
SRC_DIR="$WORK_DIR/renku"
if [ ! -d "$SRC_DIR/.git" ]; then
	# A full clone, tags included: the build derives its revision from
	# `git describe` against the hrev* tags, and a shallow clone has none.
	git clone "$RENKU_REPO" "$SRC_DIR"
fi
if [ ! -d buildtools/.git ]; then
	# RenkuOS has no buildtools fork; .github/toolchain.pin in its tree
	# points at upstream master, and so does this.
	git clone https://github.com/haiku/buildtools.git
fi

# The commit the published nightly image was built from.
#
# Not the "nightly" tag. The nightly workflow re-publishes the release with
# `gh release edit`, which never moves the tag, so the tag still names the
# commit of the very first nightly while the ISO attached to that release was
# built from something weeks newer. The workflow does write the real commit
# into the release notes as a "| Commit | <sha> |" row, so read it from there.
resolve_nightly_commit() {
	wget -qO- "$RENKU_API/releases/tags/nightly" 2>/dev/null \
		| grep -o '| Commit | [0-9a-f]\{40\}' \
		| grep -o '[0-9a-f]\{40\}' \
		| head -1
}

if [ -z "${RENKU_REF:-}" ]; then
	RENKU_REF="$(resolve_nightly_commit || true)"
	if [ -n "$RENKU_REF" ]; then
		log "RenkuOS nightly was built from $RENKU_REF"
		if [ "$RENKU_REF" != "$VERIFIED_RENKU_REF" ]; then
			log "Note: the patch was last verified against $VERIFIED_RENKU_REF;" \
				"a three-way merge below covers code that merely moved"
		fi
	else
		RENKU_REF="$VERIFIED_RENKU_REF"
		log "Could not read the nightly release; using the verified commit" \
			"$RENKU_REF"
	fi
fi

log "Checking out RenkuOS/Source ref: $RENKU_REF"
git -C "$SRC_DIR" fetch --tags origin
git -C "$SRC_DIR" fetch origin "$RENKU_REF" 2>/dev/null || true
TARGET_COMMIT="$(git -C "$SRC_DIR" rev-parse --verify "$RENKU_REF^{commit}")"
if [ "$(git -C "$SRC_DIR" rev-parse HEAD)" != "$TARGET_COMMIT" ]; then
	# The nightly moves, and this tree carries the previous run's patches.
	# It is a work tree this script owns, so discard them before switching.
	git -C "$SRC_DIR" reset --hard --quiet
	git -C "$SRC_DIR" clean -fdq
	git -C "$SRC_DIR" checkout --quiet --detach "$TARGET_COMMIT"
fi

# determine_haiku_revision requires at least one reachable hrev* tag. A full
# RenkuOS clone has them (the nightly describes as hrev60072+N); this only
# guards against a clone made without tags.
if ! git -C "$SRC_DIR" describe --tags --match='hrev*' >/dev/null 2>&1; then
	log "No hrev* tag reachable from HEAD, adding a placeholder"
	git -C "$SRC_DIR" tag hrev99000 HEAD
fi

# ---------------------------------------------------------------------------
log "Applying VAIO P patches"
# ---------------------------------------------------------------------------
PATCH_FILE="$SCRIPT_DIR/vaio-p-patches.diff"
[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"

if git -C "$SRC_DIR" apply --check --reverse "$PATCH_FILE" >/dev/null 2>&1; then
	log "Patches already applied, skipping"
else
	# -3 (three-way) rather than a plain apply: the nightly moves daily, so
	# hunks whose surrounding code merely shifted should merge on their own
	# instead of failing the whole build. It only leaves conflict markers when
	# a hunk genuinely disagrees with the tree -- usually because RenkuOS (or
	# the upstream it imports) fixed the same bug, in which case the RenkuOS
	# version wins and the hunk should be dropped, not re-derived. See
	# "Patch baseline" in AGENTS.md.
	if ! git -C "$SRC_DIR" apply -3 "$PATCH_FILE" 2>/tmp/vaio-p-apply.log; then
		cat /tmp/vaio-p-apply.log >&2
		git -C "$SRC_DIR" diff --name-only --diff-filter=U >&2 || true
		die "patch does not apply against this RenkuOS revision, even with a" \
			"three-way merge. The conflicting files are listed above (also" \
			"left in the working tree with conflict markers). See \"Patch" \
			"baseline\" in AGENTS.md next to this script: if RenkuOS already" \
			"carries the same fix, keep its version and drop the hunk;" \
			"otherwise re-derive it -- then regenerate the diff."
	fi
fi

# ---------------------------------------------------------------------------
log "Fetching packages the image injects as plain files"
# ---------------------------------------------------------------------------
# The patched build/jam/DefaultBuildProfiles drops these into /system/packages
# directly, looking for them in vaio-p-packages beside the source tree. They are
# not in the x86_gcc2 repository definition, so the build cannot fetch them
# itself and fails with "don't know how to make <file>" without them. Keep this
# list in step with vaioPExtraPackages there.
EXTRA_PACKAGES_DIR="$WORK_DIR/vaio-p-packages"
EXTRA_PACKAGES_URL="https://eu.hpkg.haiku-os.org/haikuports/master/x86_gcc2/current/packages"
EXTRA_PACKAGES=(
	vim_x86-9.1.1618-1-x86_gcc2.hpkg
)
mkdir -p "$EXTRA_PACKAGES_DIR"
for package in "${EXTRA_PACKAGES[@]}"; do
	target="$EXTRA_PACKAGES_DIR/$package"
	# A package file starts with the "hpkg" magic; anything else is an error
	# page saved under the package's name.
	if [ -f "$target" ] && [ "$(head -c 4 "$target")" = "hpkg" ]; then
		continue
	fi
	log "Downloading $package"
	wget -q -O "$target.part" "$EXTRA_PACKAGES_URL/$package" \
		|| die "could not download $package from $EXTRA_PACKAGES_URL" \
			"-- HaikuPorts may have replaced that version. Update the" \
			"filename here and in vaioPExtraPackages in DefaultBuildProfiles."
	[ "$(head -c 4 "$target.part")" = "hpkg" ] \
		|| die "$package downloaded, but is not a package file"
	mv "$target.part" "$target"
done

# ---------------------------------------------------------------------------
log "Choosing an output directory that can hold extended attributes"
# ---------------------------------------------------------------------------
# Haiku's build stores BeOS file attributes -- what SetType, mimeset and
# friends write -- as Linux extended attributes on the built files. If the
# output tree sits on a filesystem that cannot hold them, every setxattr
# fails, and it fails *silently*: the build succeeds and produces an image
# whose files have lost their types.
#
# That is not hypothetical. Built on a macOS sparsebundle shared into Docker
# over virtiofs (which returns ENOTSUP for setxattr), the image shipped
# data/deskbar/menu_entries as text/plain instead of
# application/x-vnd.haiku-virtual-directory. Tracker then does not recognise
# it as a virtual directory, and the whole Deskbar leaf menu comes up reading
# "<Deskbar folder is empty>" on the booted system.
#
# So probe first, and refuse to build rather than ship a broken image.
xattr_works() {
	local dir="$1" probe rc
	mkdir -p "$dir" 2>/dev/null || return 1
	probe="$dir/.xattr-probe.$$"
	: > "$probe" 2>/dev/null || return 1
	setfattr -n user.haiku.probe -v ok "$probe" >/dev/null 2>&1
	rc=$?
	if [ $rc -eq 0 ]; then
		getfattr --only-values -n user.haiku.probe "$probe" >/dev/null 2>&1 || rc=1
	fi
	rm -f "$probe"
	return $rc
}

GENDIR="$WORK_DIR/generated.x86_gcc2h"

if xattr_works "$WORK_DIR"; then
	log "Output directory $GENDIR holds extended attributes"
else
	# XATTR_OUTPUT_DIR is where the Docker wrapper mounts a real Linux volume.
	XATTR_OUTPUT_DIR="${XATTR_OUTPUT_DIR:-/haiku-gen}"
	if xattr_works "$XATTR_OUTPUT_DIR"; then
		GENDIR="$XATTR_OUTPUT_DIR/generated.x86_gcc2h"
		log "$WORK_DIR cannot hold extended attributes; building in $GENDIR instead"
	else
		die "neither $WORK_DIR nor $XATTR_OUTPUT_DIR supports extended" \
			"attributes." \
			"Haiku stores file types as xattrs, so building here would" \
			"silently produce an image with the wrong types (a Deskbar" \
			"menu reading \"<Deskbar folder is empty>\" is the usual" \
			"symptom)." \
			"Point XATTR_OUTPUT_DIR at a directory on a filesystem that" \
			"supports them -- with the Docker wrapper that is a named" \
			"volume, not the shared build volume."
	fi
fi

# ---------------------------------------------------------------------------
log "Building cross-tools (x86_gcc2 + x86)"
# ---------------------------------------------------------------------------
CROSS_TOOLS_READY=0
if [ -d "$GENDIR/cross-tools-x86_gcc2/bin" ] && [ -d "$GENDIR/cross-tools-x86/bin" ]; then
	CROSS_TOOLS_READY=1
fi

if [ "${SKIP_CROSS_TOOLS:-0}" = "1" ] && [ "$CROSS_TOOLS_READY" = "1" ]; then
	log "Cross-tools already present, skipping (SKIP_CROSS_TOOLS=1)"
else
	rm -rf "$GENDIR"
	mkdir -p "$GENDIR"
	(
		cd "$GENDIR"
		HOST_AWK="$(command -v gawk || command -v awk)" \
			"$SRC_DIR/configure" \
			--build-cross-tools x86_gcc2 \
			--build-cross-tools x86 \
			--cross-tools-source "$WORK_DIR/buildtools" \
			--distro-compatibility "$DISTRO_COMPATIBILITY" \
			--use-gcc-pipe -j"$JOBS"
	)
fi

# ---------------------------------------------------------------------------
log "Building jam"
# ---------------------------------------------------------------------------
JAM_BIN="$WORK_DIR/buildtools/jam/bin.linux$(uname -m | sed 's/x86_64/x86/;s/aarch64/arm/')/jam"
if [ ! -x "$JAM_BIN" ]; then
	(cd "$WORK_DIR/buildtools/jam" && make)
	JAM_BIN="$(find "$WORK_DIR/buildtools/jam" -maxdepth 1 -type d -name 'bin.*' \
		-exec test -x '{}/jam' ';' -print -quit)/jam"
fi
[ -x "$JAM_BIN" ] || die "jam build did not produce an executable, check the output above"

# ---------------------------------------------------------------------------
log "Building RenkuOS (jam -q @nightly-anyboot) -- this is the slow part"
# ---------------------------------------------------------------------------
export PATH="$(dirname "$JAM_BIN"):$PATH"
# Same label the RenkuOS nightly brands its images with. Exported rather than
# written to UserBuildConfig: the nightly workflow found that only the export
# reliably reaches jam.
export HAIKU_IMAGE_LABEL="$IMAGE_LABEL"
(cd "$GENDIR" && jam -q -j"$JOBS" @nightly-anyboot)

# ---------------------------------------------------------------------------
log "Done -- copying ISO to $OUTPUT_ISO"
# ---------------------------------------------------------------------------
ISO_SRC="$(find "$GENDIR" -maxdepth 1 -name '*anyboot*.iso' | head -1)"
[ -n "$ISO_SRC" ] && [ -f "$ISO_SRC" ] || die "expected an anyboot ISO in $GENDIR"
mkdir -p "$(dirname "$OUTPUT_ISO")"
cp "$ISO_SRC" "$OUTPUT_ISO"

log "Built: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "Write it to a USB stick with: sudo dd if=$OUTPUT_ISO of=/dev/rXXX bs=4m"
