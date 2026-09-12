#!/bin/bash
#
# Build a Docker base image from the official DietPi container image.
#
# DietPi does not publish a Docker image (see MichaIng/DietPi#5924); what it
# does publish is a container *disk image* (DietPi_Container-<arch>-<distro>.img.xz).
# This script turns one into a Docker base image without needing root, loop
# devices or --privileged on the host: the extraction runs inside a throwaway
# container which dumps the ext4 root partition with debugfs, so no mount is
# involved. That keeps it usable both locally and on a CI runner.
#
# The download is checked against the sha256 DietPi publishes alongside it.
#
# Usage: tests/docker/build-dietpi-base.sh [arch] [distro]
#   arch:   x86_64 (default) | ARMv8 | ARMv7 | ARMv6
#   distro: Bookworm (default) | Trixie | Forky
#
# Result: a local image tagged dietpi-base:<distro-lowercase>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly ARCH="${1:-x86_64}"
readonly DISTRO="${2:-Bookworm}"
readonly IMAGE_NAME="DietPi_Container-${ARCH}-${DISTRO}.img.xz"
readonly BASE_URL="https://dietpi.com/downloads/images"
readonly TAG="dietpi-base:${DISTRO,,}"
readonly CACHE_DIR="${DIETPI_CACHE_DIR:-${TMPDIR:-/tmp}/dietpi-images}"
# Debian image used only as the extraction toolbox.
readonly TOOLBOX="debian:bookworm-slim"

log () { printf '==> %s\n' "$*"; }

if docker image inspect "$TAG" &> /dev/null && [ -z "${FORCE_REBUILD:-}" ]
then
  log "$TAG already exists (set FORCE_REBUILD=1 to rebuild)"
  exit 0
fi

mkdir -p "$CACHE_DIR"

# --- download + verify -----------------------------------------------------
if [ ! -s "$CACHE_DIR/$IMAGE_NAME" ]
then
  log "downloading $IMAGE_NAME"
  curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME" "$BASE_URL/$IMAGE_NAME"
fi

log "verifying sha256"
curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME.sha256" "$BASE_URL/$IMAGE_NAME.sha256"
(
  cd "$CACHE_DIR"
  sha256sum -c "$IMAGE_NAME.sha256"
)

# --- extract the root filesystem -------------------------------------------
# Runs as root inside the toolbox container so file ownership survives.
log "extracting root filesystem (this takes a minute)"
docker run --rm \
  -v "$CACHE_DIR:/cache" \
  -v "$SCRIPT_DIR/extract-dietpi-rootfs.sh:/extract.sh:ro" \
  -e "IMAGE_NAME=$IMAGE_NAME" \
  "$TOOLBOX" \
  bash /extract.sh

# --- import ----------------------------------------------------------------
log "importing as $TAG"
docker import \
  --change 'CMD ["/bin/bash"]' \
  --change 'ENV DEBIAN_FRONTEND=noninteractive' \
  "$CACHE_DIR/dietpi-rootfs.tar" "$TAG" > /dev/null
rm -f "$CACHE_DIR/dietpi-rootfs.tar"

log "verifying the image runs"
docker run --rm "$TAG" bash -c 'cat /etc/os-release | head -2; ls /boot/dietpi/ &> /dev/null && echo "DietPi payload present"'

log "done: $TAG"
