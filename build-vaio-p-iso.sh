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
#                        Default: leave whatever is currently checked out
#                        (or "master" on a fresh clone).
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
REQUIRED_CMDS=(git wget gcc g++ make bison flex gawk nasm autoconf automake
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

if [ -n "${HAIKU_GIT_REF:-}" ]; then
	log "Checking out haiku.git ref: $HAIKU_GIT_REF"
	git -C haiku fetch origin "$HAIKU_GIT_REF"
	git -C haiku checkout FETCH_HEAD
fi

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
	if ! git -C haiku apply --check "$PATCH_FILE" 2>/tmp/vaio-p-apply-check.log; then
		cat /tmp/vaio-p-apply-check.log >&2
		die "patch no longer applies cleanly against this Haiku revision." \
			"See README.VAIO-P-PATCHES.md at the repo root (in the patch" \
			"file's own history / your checkout of this tooling) for what" \
			"each patch does, and re-derive the failing hunk(s) by hand" \
			"against the current source before re-running this script."
	fi
	git -C haiku apply "$PATCH_FILE"
fi

# ---------------------------------------------------------------------------
log "Building cross-tools (x86_gcc2 + x86)"
# ---------------------------------------------------------------------------
GENDIR="$WORK_DIR/generated.x86_gcc2h"
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
