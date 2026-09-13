#!/bin/bash
#
# Automation_Custom_Script.sh - teslausb bootstrap for DietPi.
#
# Copy this to the boot partition of a freshly flashed DietPi image, next to
# dietpi.txt, and set AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1 in dietpi.txt. DietPi runs
# it once, at the end of its own first-boot setup, as root with networking up.
#
# This replaces the pi-gen image build teslausb used on Raspberry Pi OS: instead
# of baking a custom image, an official DietPi image configures itself and then
# hands over to teslausb.
#
# All it does is install the setup driver and start it. Everything else is
# teslausb's normal setup, which reboots as needed and resumes through
# teslausb-setup.service.

set -uo pipefail

readonly REPO="${REPO:-nich227}"
readonly BRANCH="${BRANCH:-main-dev}"
readonly RAW="https://raw.githubusercontent.com/${REPO}/teslausb/${BRANCH}"
readonly LOG=/boot/teslausb-headless-setup.log

log () {
  echo "$(date) : $*" >> "$LOG" 2>/dev/null || true
  echo "$*"
}

fetch () {
  local url="$1" dest="$2" tries=0
  local name="${url##*/}"

  # An offline copy on the boot partition wins. This is what lets an install run
  # without reaching GitHub, and it is how the VM test exercises the working tree
  # rather than whatever is currently published.
  if [ -f "/boot/teslausb-local/$name" ]
  then
    log "using /boot/teslausb-local/$name"
    cp "/boot/teslausb-local/$name" "$dest"
    return 0
  fi

  until curl -fsSL --retry 3 -o "$dest" "$url"
  do
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 5 ]
    then
      log "FATAL: could not download $url"
      return 1
    fi
    log "download of $url failed, retrying"
    sleep 5
  done
}

log "teslausb bootstrap starting on DietPi $(sed -n 's/^G_DIETPI_VERSION_CORE=//p' /boot/dietpi/.version 2>/dev/null)"

# DietPi-RAMlog and teslausb both want to own /var/log as a tmpfs, and DietPi's
# version writes to the root filesystem when it stops, which does not work once
# the root is read-only.
#
# This script is normally run BY dietpi-software, during DietPi's first run
# setup, and DietPi refuses to run a second instance of itself while one is
# active. So only remove it here if we are not nested inside it; otherwise leave
# it to teslausb's own setup, which does the same thing later from
# make-root-fs-readonly.sh, outside dietpi-software.
if grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab 2> /dev/null
then
  if pgrep -f '/boot/dietpi/dietpi-software' | grep -qv "^$$\$"
  then
    log "DietPi-RAMlog is still installed; teslausb setup will remove it later"
    log "(dietpi-software is running this script, so it cannot be called again now)"
  else
    log "removing DietPi-RAMlog so teslausb can own /var/log"
    /boot/dietpi/dietpi-software uninstall 103 >> "$LOG" 2>&1 ||
      log "WARNING: could not uninstall DietPi-RAMlog; teslausb setup will retry later"
  fi
fi

# curl and dos2unix are needed to fetch and sanitise the config; DietPi has curl
# but not dos2unix.
if ! command -v dos2unix > /dev/null
then
  log "installing dos2unix"
  apt-get -qq update >> "$LOG" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get -qq -y install dos2unix >> "$LOG" 2>&1 ||
    log "WARNING: could not install dos2unix"
fi

mkdir -p /root/bin

log "installing the teslausb setup driver"
fetch "$RAW/setup/pi/first-boot.sh" /root/bin/first-boot.sh || exit 1
chmod +x /root/bin/first-boot.sh
fetch "$RAW/setup/pi/teslausb-setup.service" /lib/systemd/system/teslausb-setup.service || exit 1

systemctl daemon-reload
systemctl enable teslausb-setup.service

log "handing over to teslausb setup"
# Run it now rather than waiting for the next boot, so a user watching the
# DietPi first-boot output sees setup continue straight away.
/root/bin/first-boot.sh
