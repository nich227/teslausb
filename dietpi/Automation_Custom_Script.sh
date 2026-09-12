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

# DietPi-RAMlog keeps /var/log in tmpfs and holds it open, which prevents
# teslausb from remounting the root filesystem read-only later on. Take it out
# now, before anything else is installed, so setup starts from a clean state.
if grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab 2> /dev/null
then
  log "removing DietPi-RAMlog so the root filesystem can be made read-only"
  /boot/dietpi/dietpi-software uninstall 103 >> "$LOG" 2>&1 ||
    log "WARNING: could not uninstall DietPi-RAMlog; do it with dietpi-software before setup"
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
