# Test image for the teslausb integration tests.
#
# The base is built from the official DietPi container image by
# tests/docker/build-dietpi-base.sh, because DietPi publishes no Docker image
# of its own (MichaIng/DietPi#5924). Using DietPi rather than plain Debian
# means the scripts are exercised against the same stripped-down userland the
# device actually runs.
ARG BASE_IMAGE=dietpi-base:bookworm
FROM ${BASE_IMAGE}

# Deliberately minimal. A bare DietPi has almost nothing, and the point of
# these tests is to catch a dependency the watchdog assumes but DietPi omits,
# so nothing is installed here to paper that over. systemd is already present
# in the DietPi container image, which gives us a real systemd-analyze.
SHELL ["/bin/bash", "-c"]

# jq is the one exception to installing nothing: the USB link watchdog and
# sentry-keeper parse Tessie's JSON with it, so without it those code paths
# cannot run at all here. The suite separately asserts that teslausb's own setup
# installs it, which is what covers the real device.
# /tmp has to be world writable with the sticky bit, as it is on a real device. The
# rootfs is extracted with "debugfs rdump", which does not reproduce it faithfully, and
# apt's gpgv method drops to the unprivileged _apt user to verify signatures: with a /tmp
# it cannot write to, it fails to create its temporary config, reports every repository
# as "not signed" and exits 100. That happens on the CI runner but not on a workstation,
# so it looked like a network problem for a while.
RUN mkdir -p /tmp && chmod 1777 /tmp && \
    apt-get -q update && \
    apt-get -q install -y --no-install-recommends jq && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /repo
COPY . /repo

ENTRYPOINT ["bash", "/repo/tests/integration-test.sh"]
