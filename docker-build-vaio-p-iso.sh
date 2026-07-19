#!/bin/bash
#
# macOS-side wrapper: sets up a case-sensitive disk image and a Linux
# (Ubuntu) Docker container, then runs build-vaio-p-iso.sh inside it to
# produce a Haiku ISO patched for the Sony VAIO P (VGN-P70H_G).
#
# Why this exists: the legacy x86_gcc2 cross-compiler needs -m32 host
# support, which modern macOS SDKs no longer provide (neither native arm64
# nor Rosetta/x86_64 can link i386 binaries anymore). Building on Linux
# sidesteps this entirely. See README.VAIO-P-PATCHES.md's "Build
# environment notes" section for the full story.
#
# Requirements on the Mac:
#   - Docker Desktop, with Settings > General > "Use Virtualization
#     Framework" and "Use Rosetta for x86/amd64 emulation" both ON. Without
#     Rosetta, the container runs under full QEMU emulation and the build
#     can take many hours instead of ~1-2.
#
# Usage:
#   ./docker-build-vaio-p-iso.sh [output-iso-path]
#
# Environment variables (forwarded to build-vaio-p-iso.sh inside the
# container, see that script's header for details):
#   SKIP_CROSS_TOOLS, HAIKU_GIT_REF, JOBS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ISO="${1:-$PWD/haiku-vaio-p.iso}"

DMG_PATH="${VAIO_P_DMG_PATH:-$HOME/HaikuBuild.sparseimage}"
VOLUME_NAME="HaikuBuild"
VOLUME_PATH="/Volumes/$VOLUME_NAME"
CONTAINER_NAME="haiku-builder"
IMAGE_NAME="ubuntu:22.04"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
	die "this wrapper is for macOS; on Linux just run build-vaio-p-iso.sh directly"
fi

command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Desktop first"
docker info >/dev/null 2>&1 || die "Docker daemon not reachable — is Docker Desktop running? (open -a Docker)"

# ---------------------------------------------------------------------------
log "Setting up case-sensitive build volume"
# ---------------------------------------------------------------------------
# APFS is case-insensitive by default, but the Haiku source tree relies on
# case-sensitive paths. A dedicated sparse disk image sidesteps reformatting
# the whole Mac.
if [ ! -d "$VOLUME_PATH" ]; then
	if [ ! -f "$DMG_PATH" ]; then
		log "Creating case-sensitive sparse disk image at $DMG_PATH (60GB max, grows as needed)"
		hdiutil create -type SPARSE -size 60g -fs "Case-sensitive APFS" \
			-volname "$VOLUME_NAME" "$DMG_PATH"
	fi
	log "Mounting $DMG_PATH"
	hdiutil attach "${DMG_PATH}.sparseimage" -mountpoint "$VOLUME_PATH"
fi

# ---------------------------------------------------------------------------
log "Setting up the haiku-builder container"
# ---------------------------------------------------------------------------
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	log "Creating container $CONTAINER_NAME ($IMAGE_NAME, linux/amd64, Rosetta-accelerated)"
	docker run -d --name "$CONTAINER_NAME" \
		--platform linux/amd64 \
		-v "$VOLUME_PATH:/haiku-build" \
		"$IMAGE_NAME" \
		sleep infinity
elif [ "$(docker container inspect -f '{{.State.Status}}' "$CONTAINER_NAME")" != "running" ]; then
	log "Starting existing (stopped) container $CONTAINER_NAME"
	docker start "$CONTAINER_NAME"
fi

# ---------------------------------------------------------------------------
log "Copying build script and patch into the container"
# ---------------------------------------------------------------------------
docker exec "$CONTAINER_NAME" mkdir -p /haiku-build/tools/vaio-p
docker cp "$SCRIPT_DIR/build-vaio-p-iso.sh" "$CONTAINER_NAME:/haiku-build/tools/vaio-p/build-vaio-p-iso.sh"
docker cp "$SCRIPT_DIR/vaio-p-patches.diff" "$CONTAINER_NAME:/haiku-build/tools/vaio-p/vaio-p-patches.diff"
docker exec "$CONTAINER_NAME" chmod +x /haiku-build/tools/vaio-p/build-vaio-p-iso.sh

# ---------------------------------------------------------------------------
log "Running the build inside the container (this is the slow part)"
# ---------------------------------------------------------------------------
docker exec \
	-e SKIP_CROSS_TOOLS="${SKIP_CROSS_TOOLS:-0}" \
	${HAIKU_GIT_REF:+-e HAIKU_GIT_REF="$HAIKU_GIT_REF"} \
	${JOBS:+-e JOBS="$JOBS"} \
	"$CONTAINER_NAME" \
	/haiku-build/tools/vaio-p/build-vaio-p-iso.sh \
	/haiku-build/work \
	/haiku-build/haiku-vaio-p.iso

# ---------------------------------------------------------------------------
log "Copying finished ISO out to the Mac"
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_ISO")"
cp "$VOLUME_PATH/haiku-vaio-p.iso" "$OUTPUT_ISO"

log "Built: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "Write it to a USB stick with: sudo dd if=$OUTPUT_ISO of=/dev/rdiskN bs=4m"
