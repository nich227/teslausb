#! /bin/bash

shopt -s globstar nullglob extglob

# print shellcheck version so we know what Github uses
shellcheck -V

# SC1091 - Don't complain about not being able to find files that don't exist.
shellcheck --exclude=SC1091 \
           ./setup/pi/setup-teslausb \
           ./setup/pi/first-boot.sh \
           ./dietpi/Automation_Custom_Script.sh \
           ./run/archiveloop \
           ./run/auto.teslausb \
           ./run/awake_start \
           ./run/awake_stop \
           ./run/mountimage \
           ./run/mountoptsforimage \
           ./run/remountfs_rw \
           ./run/send-push-message \
           ./run/temperature_monitor \
           ./run/usb-link-watchdog.sh \
           ./run/waitforidle \
           ./tests/usb-link-watchdog-test.sh \
           ./tests/integration-test.sh \
           ./tests/run-integration-tests.sh \
           ./tests/coverage.sh \
           ./tools/prepare-boot-partition.sh \
           ./tests/docker/build-dietpi-base.sh \
           ./tests/docker/extract-dietpi-rootfs.sh
