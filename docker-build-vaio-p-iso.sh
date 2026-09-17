#!/bin/bash
#
# macOS-side wrapper: sets up a Linux (Ubuntu, amd64) Docker container and
# runs build-vaio-p-iso.sh inside it to produce a 32-bit RenkuOS ISO patched
# for the Sony VAIO P (VGN-P70H_G), built from the source of the current
# RenkuOS nightly.
#
# Why this exists: the legacy x86_gcc2 cross-compiler needs -m32 host
# support, which neither macOS nor arm64 Linux provide. Building in an amd64
# Linux container sidesteps this entirely.
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
#   SKIP_CROSS_TOOLS, RENKU_REF, DISTRO_COMPATIBILITY, IMAGE_LABEL, JOBS
# and, for this wrapper only:
#   CONTAINER_NAME       Build container name. Default: vaio-p-builder.
#   WORK_VOLUME_NAME     Docker volume holding the whole build. Default:
#                        haiku-vaio-p-work.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ISO="${1:-$PWD/renku-vaio-p.iso}"

# Not the generic "haiku-builder": that name is easily already taken by an
# arm64 container used for other Haiku work, and reusing it would try to build
# the i386-hosted x86_gcc2 compiler on arm64, which cannot work.
CONTAINER_NAME="${CONTAINER_NAME:-vaio-p-builder}"

# Everything -- source tree, buildtools, cross-tools, objects -- lives on a
# Docker named volume, a real Linux filesystem, and nothing on a macOS bind
# mount. Haiku's build reads and writes file types as extended attributes, and
# a bind mount reaches the container over virtiofs, which returns ENOTSUP for
# them. Both directions have bitten:
#   - output on the bind mount built "successfully" but shipped files with no
#     types (a Deskbar leaf menu reading "<Deskbar folder is empty>", because
#     data/deskbar/menu_entries came out as text/plain);
#   - the source tree on the bind mount failed at the very last step, when the
#     image is populated: "Failed to open source path .../data/etc/inputrc:
#     Operation not supported".
# A named volume is also case-sensitive, which the Haiku tree requires, so no
# case-sensitive disk image is needed on the Mac side either.
WORK_VOLUME_NAME="${WORK_VOLUME_NAME:-haiku-vaio-p-work}"
WORK_MOUNT="/vaio-p"
IMAGE_NAME="ubuntu:22.04"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
	die "this wrapper is for macOS; on Linux just run build-vaio-p-iso.sh directly"
fi

command -v docker >/dev/null 2>&1 || die "docker not found -- install Docker Desktop first"
docker info >/dev/null 2>&1 || die "Docker daemon not reachable -- is Docker Desktop running? (open -a Docker)"

# ---------------------------------------------------------------------------
log "Setting up the $CONTAINER_NAME container"
# ---------------------------------------------------------------------------
docker volume inspect "$WORK_VOLUME_NAME" >/dev/null 2>&1 \
	|| docker volume create "$WORK_VOLUME_NAME" >/dev/null

if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	log "Creating container $CONTAINER_NAME ($IMAGE_NAME, linux/amd64, Rosetta-accelerated)"
	docker run -d --name "$CONTAINER_NAME" \
		--platform linux/amd64 \
		-v "$WORK_VOLUME_NAME:$WORK_MOUNT" \
		"$IMAGE_NAME" \
		sleep infinity >/dev/null
elif [ "$(docker container inspect -f '{{.State.Status}}' "$CONTAINER_NAME")" != "running" ]; then
	log "Starting existing (stopped) container $CONTAINER_NAME"
	docker start "$CONTAINER_NAME" >/dev/null
fi

CONTAINER_ARCH="$(docker exec "$CONTAINER_NAME" uname -m)"
[ "$CONTAINER_ARCH" = "x86_64" ] \
	|| die "container $CONTAINER_NAME is $CONTAINER_ARCH, not x86_64. The" \
		"x86_gcc2 cross-compiler needs an amd64 (i386-capable) host. Remove" \
		"it or set CONTAINER_NAME to another name."

docker exec "$CONTAINER_NAME" test -d "$WORK_MOUNT" \
	|| die "container $CONTAINER_NAME has no $WORK_MOUNT volume -- it was" \
		"created by an older version of this script. Remove it" \
		"(docker rm -f $CONTAINER_NAME) and run this again."

# ---------------------------------------------------------------------------
log "Copying build script and patch into the container"
# ---------------------------------------------------------------------------
docker exec "$CONTAINER_NAME" mkdir -p "$WORK_MOUNT/tools"
docker cp "$SCRIPT_DIR/build-vaio-p-iso.sh" "$CONTAINER_NAME:$WORK_MOUNT/tools/build-vaio-p-iso.sh"
docker cp "$SCRIPT_DIR/vaio-p-patches.diff" "$CONTAINER_NAME:$WORK_MOUNT/tools/vaio-p-patches.diff"
docker exec "$CONTAINER_NAME" chmod +x "$WORK_MOUNT/tools/build-vaio-p-iso.sh"

# ---------------------------------------------------------------------------
log "Running the build inside the container (this is the slow part)"
# ---------------------------------------------------------------------------
docker exec \
	-e SKIP_CROSS_TOOLS="${SKIP_CROSS_TOOLS:-0}" \
	${RENKU_REF:+-e RENKU_REF="$RENKU_REF"} \
	${DISTRO_COMPATIBILITY:+-e DISTRO_COMPATIBILITY="$DISTRO_COMPATIBILITY"} \
	${IMAGE_LABEL:+-e IMAGE_LABEL="$IMAGE_LABEL"} \
	${JOBS:+-e JOBS="$JOBS"} \
	"$CONTAINER_NAME" \
	"$WORK_MOUNT/tools/build-vaio-p-iso.sh" \
	"$WORK_MOUNT/work" \
	"$WORK_MOUNT/renku-vaio-p.iso"

# ---------------------------------------------------------------------------
log "Copying finished ISO out to the Mac"
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_ISO")"
docker cp "$CONTAINER_NAME:$WORK_MOUNT/renku-vaio-p.iso" "$OUTPUT_ISO"

log "Built: $OUTPUT_ISO ($(du -h "$OUTPUT_ISO" | cut -f1))"
echo "Write it to a USB stick with: sudo dd if=$OUTPUT_ISO of=/dev/rdiskN bs=4m"
