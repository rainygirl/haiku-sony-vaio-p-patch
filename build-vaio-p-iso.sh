#!/bin/bash
#
# Build a Haiku x86_gcc2h anyboot ISO patched for the Sony VAIO P
# (VGN-P70H_G) — see README.VAIO-P-PATCHES.md and AGENTS.md at the repo
# root for what these patches are and why they exist.
#
# This script is meant to run INSIDE a Linux (Ubuntu/Debian) environment —
# building the legacy x86_gcc2 cross-compiler requires -m32 host support,
# which modern macOS SDKs no longer provide at all. On macOS, use
# docker-build-vaio-p-iso.sh instead, which sets up a Linux container and
# runs this script inside it. See the "Build environment notes" section of
# README.VAIO-P-PATCHES.md for the full explanation.
#
# Usage:
#   ./build-vaio-p-iso.sh [work-dir] [output-iso-path]
#
#   work-dir          Directory to clone/build in. Reused across runs if it
#                      already has haiku/buildtools checked out (default:
#                      ./vaio-p-work next to this script).
#   output-iso-path    Where to copy the finished ISO (default:
#                      ./haiku-vaio-p.iso in the current directory).
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
#   HAIKU_GIT_REF        Branch/tag/commit of haiku.git to check out.
#                        Default: the pinned nightly commit the patch was
#                        generated from and verified against (see below).
#                        Set to "master" to track the tip instead -- the
#                        patch may or may not still apply there.
#   JOBS                 Parallelism for configure/jam. Default: nproc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${1:-$SCRIPT_DIR/vaio-p-work}"
OUTPUT_ISO="${2:-$PWD/haiku-vaio-p.iso}"
JOBS="${JOBS:-$(nproc)}"

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
	log "Installing missing packages via apt (needs sudo)"
	sudo dpkg --add-architecture i386
	sudo apt-get update -qq
	sudo apt-get install -y -qq \
		build-essential gcc-multilib g++-multilib \
		bison flex gawk texinfo nasm git wget \
		autoconf automake libtool python3 zip unzip xorriso \
		zlib1g-dev zlib1g-dev:i386 libzstd-dev liblzma-dev libncurses-dev
fi

# ---------------------------------------------------------------------------
log "Fetching Haiku source"
# ---------------------------------------------------------------------------
if [ ! -d haiku/.git ]; then
	git clone https://github.com/haiku/haiku.git
fi
if [ ! -d buildtools/.git ]; then
	git clone https://github.com/haiku/buildtools.git
fi

# The nightly commit vaio-p-patches.diff was generated from and verified
# against. Pinned deliberately: haiku.git master moves several times a day,
# and an unpinned build silently mixes an untested upstream state into an
# ISO whose whole point is that it boots on one specific fragile machine.
# Bumping it is a deliberate act -- re-derive the patch against the new
# commit, rebuild, and confirm the machine still boots before committing
# the new value. Override with HAIKU_GIT_REF=master to track the tip.
HAIKU_GIT_REF="${HAIKU_GIT_REF:-8b91c532fa}"

log "Checking out haiku.git ref: $HAIKU_GIT_REF"
git -C haiku fetch origin master
git -C haiku fetch origin "$HAIKU_GIT_REF" 2>/dev/null || true
git -C haiku checkout --detach "$HAIKU_GIT_REF"

# determine_haiku_revision requires at least one reachable hrev* tag.
if ! git -C haiku describe --tags --match='hrev*' >/dev/null 2>&1; then
	log "No hrev* tag reachable from HEAD, adding a placeholder"
	git -C haiku tag hrev99000 HEAD
fi

# ---------------------------------------------------------------------------
log "Applying VAIO P patches"
# ---------------------------------------------------------------------------
PATCH_FILE="$SCRIPT_DIR/vaio-p-patches.diff"
[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"

if git -C haiku apply --check --reverse "$PATCH_FILE" >/dev/null 2>&1; then
	log "Patches already applied, skipping"
else
	# -3 (three-way) rather than a plain apply: the patch targets `master`,
	# which moves daily, so hunks whose surrounding code merely shifted
	# should merge on their own instead of failing the whole build. It only
	# leaves conflict markers when a hunk genuinely disagrees with upstream
	# -- usually because upstream fixed the same bug, in which case the hunk
	# should be dropped, not re-derived. See "Patch baseline" in README.md.
	if ! git -C haiku apply -3 "$PATCH_FILE" 2>/tmp/vaio-p-apply.log; then
		cat /tmp/vaio-p-apply.log >&2
		git -C haiku diff --name-only --diff-filter=U >&2 || true
		die "patch does not apply against this Haiku revision, even with a" \
			"three-way merge. The conflicting files are listed above (also" \
			"left in the working tree with conflict markers). See \"Patch" \
			"baseline\" in README.md next to this script: check whether" \
			"upstream already carries the same fix -- if so drop the hunk," \
			"otherwise re-derive it -- then regenerate the diff."
	fi
fi

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
			"$WORK_DIR/haiku/configure" \
			--build-cross-tools x86_gcc2 \
			--build-cross-tools x86 \
			--cross-tools-source "$WORK_DIR/buildtools" \
			--distro-compatibility official \
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
log "Building Haiku (jam -q @nightly-anyboot) — this is the slow part"
# ---------------------------------------------------------------------------
export PATH="$(dirname "$JAM_BIN"):$PATH"
(cd "$GENDIR" && jam -q @nightly-anyboot)

# ---------------------------------------------------------------------------
log "Done — copying ISO to $OUTPUT_ISO"
# ---------------------------------------------------------------------------
ISO_SRC="$GENDIR/haiku-nightly-anyboot.iso"
[ -f "$ISO_SRC" ] || die "expected ISO not found at $ISO_SRC"
mkdir -p "$(dirname "$OUTPUT_ISO")"
cp "$ISO_SRC" "$OUTPUT_ISO"

log "Built: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "Write it to a USB stick with: sudo dd if=$OUTPUT_ISO of=/dev/rXXX bs=4m"
