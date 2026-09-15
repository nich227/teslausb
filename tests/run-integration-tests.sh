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
"$REPO/tests/package-install-test.sh"
"$REPO/tests/ap-channel-test.sh"

# --- integration tests -----------------------------------------------------
log "DietPi base image ($BASE_TAG)"
"$SCRIPT_DIR/docker/build-dietpi-base.sh" "$ARCH" "$DISTRO"

log "building $TEST_TAG"
# Output is captured rather than discarded: a failing build here used to print the
# Dockerfile excerpt and nothing else, since the reason goes to stdout.
build_log=$(mktemp)
if ! docker build \
  --progress=plain \
  --build-arg "BASE_IMAGE=$BASE_TAG" \
  -f "$SCRIPT_DIR/docker/Dockerfile" \
  -t "$TEST_TAG" \
  "$REPO" > "$build_log" 2>&1
then
  echo "build of $TEST_TAG failed:"
  cat "$build_log"
  rm -f "$build_log"
  exit 1
fi
rm -f "$build_log"

log "integration tests in DietPi $DISTRO ($ARCH)"
# SYS_ADMIN (plus unconfined apparmor, which otherwise blocks mount) lets the
# suite mount a real tmpfs so the archive-in-progress guard is exercised against
# a genuine mount rather than a stub. It applies only to this throwaway
# container.
# Named, and removed on the way out. Interrupting or timing out a "docker run"
# kills the client but leaves the container running: five of them were found still
# going hours later, each stuck inside dietpi-software.
container="teslausb-test-$$"
cleanup_container () {
  docker rm -f "$container" > /dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM

docker run --rm --name "$container" \
  --cap-add=SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -e "COVERAGE=${COVERAGE:-1}" \
  -e "COVERAGE_MIN=${COVERAGE_MIN:-100}" \
  -e "SHOW_MISSED=${SHOW_MISSED:-}" \
  "$TEST_TAG"
