#!/bin/bash
#
# Runs the whole test suite: shellcheck, the watchdog unit tests, and the
# integration tests inside a DietPi container.
#
# The DietPi base image is built on first use from the official DietPi
# container image (downloaded and sha256-verified); afterwards it is reused.
#
# Usage: tests/run-integration-tests.sh [--no-lint]
#
# Environment:
#   DIETPI_DISTRO   Bookworm (default) | Trixie | Forky
#   DIETPI_ARCH     x86_64 (default) | ARMv8 | ARMv7 | ARMv6
#   FORCE_REBUILD   set to rebuild the DietPi base image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO="$SCRIPT_DIR/.."
readonly DISTRO="${DIETPI_DISTRO:-Bookworm}"
readonly ARCH="${DIETPI_ARCH:-x86_64}"
readonly BASE_TAG="dietpi-base:${DISTRO,,}"
readonly TEST_TAG="teslausb-test:${DISTRO,,}"

log () { printf '\n==> %s\n' "$*"; }

if ! command -v docker > /dev/null
then
  echo "FATAL: docker is required to run the integration tests" >&2
  exit 1
fi

# --- shellcheck ------------------------------------------------------------
if [ "${1:-}" != "--no-lint" ]
then
  log "shellcheck"
  mapfile -t shell_files < <(
    cd "$REPO" &&
    git ls-files |
      grep -E '\.sh$|^run/|rc\.local$|setup/pi/setup-teslausb' |
      grep -v '\.py$'
  )
  docker run --rm -v "$REPO:/mnt" -w /mnt koalaman/shellcheck:stable \
    --exclude=SC1091 "${shell_files[@]}"
  echo "shellcheck: clean"
fi

# --- unit tests ------------------------------------------------------------
log "unit tests"
"$REPO/tests/usb-link-watchdog-test.sh"

# --- integration tests -----------------------------------------------------
log "DietPi base image ($BASE_TAG)"
"$SCRIPT_DIR/docker/build-dietpi-base.sh" "$ARCH" "$DISTRO"

log "building $TEST_TAG"
docker build -q \
  --build-arg "BASE_IMAGE=$BASE_TAG" \
  -f "$SCRIPT_DIR/docker/Dockerfile" \
  -t "$TEST_TAG" \
  "$REPO" > /dev/null

log "integration tests in DietPi $DISTRO ($ARCH)"
# SYS_ADMIN (plus unconfined apparmor, which otherwise blocks mount) lets the
# suite mount a real tmpfs so the archive-in-progress guard is exercised against
# a genuine mount rather than a stub. It applies only to this throwaway
# container.
docker run --rm \
  --cap-add=SYS_ADMIN \
  --security-opt apparmor=unconfined \
  "$TEST_TAG"
