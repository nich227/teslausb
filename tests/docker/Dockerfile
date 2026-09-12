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

WORKDIR /repo
COPY . /repo

ENTRYPOINT ["bash", "/repo/tests/integration-test.sh"]
