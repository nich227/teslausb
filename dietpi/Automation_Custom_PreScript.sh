#!/bin/bash
#
# Configures DietPi from teslausb_setup_variables.conf before DietPi sets up the network.
#
# This exists for the flashable image, where the only thing a user can edit is the boot
# partition: it is the one partition Windows and macOS both mount, and the DietPi settings
# that matter live on the ext4 root filesystem, which they cannot read at all.
#
# DietPi does have an importer for this, in fs_partition_resize.sh, which copies
# dietpi.txt and dietpi-wifi.txt from the boot partition. It cannot be used here, because
# it shares a branch with the root partition expansion:
#
#   if [[ -f '/dietpi_skip_partition_resize' ]]; then rm ...   # skips the import too
#   elif ...
#   else   # import, then "Maximising root partition size"
#
# teslausb needs that marker, or DietPi expands the root filesystem over the whole card
# and leaves nothing for the recordings, so the import never runs.
#
# Timing is the reason this is a PreScript rather than part of the ordinary bootstrap.
# dietpi-firstboot.bash runs Automation_Custom_PreScript.sh and only then configures the
# network, reading AUTO_SETUP_NET_WIFI_ENABLED from dietpi.txt and the credentials from
# dietpi-wifi.txt. Anything later, including Automation_Custom_Script.sh, happens after
# DietPi has already tried to bring up wifi and run apt, which without a network is a
# failed first boot rather than a slow one.
#
# The work itself is left to tools/prepare-boot-partition.sh, which is what a user runs
# against a card from a Linux machine and is already covered by tests. This finds the
# config and the script and gets out of the way.
#
# It must never fail the boot: a device with no network still has to finish booting so
# there is something to log in to.

set -uo pipefail

readonly BOOT_LOG=teslausb-headless-setup.log

log () {
  echo "teslausb pre-setup: $*"
  # The same log the rest of setup writes, on the partition a headless user can read.
  [ -n "${LOG_DIR:-}" ] && echo "teslausb pre-setup: $*" >> "$LOG_DIR/$BOOT_LOG" 2> /dev/null
  return 0
}

# --- find the boot partition the user edited ---------------------------------
# On Raspberry Pi images DietPi mounts the FAT partition at /boot/firmware. Everything
# else is checked too, since this should not depend on the board.
CONF=""
LOG_DIR=""
for dir in /boot/firmware /boot /boot/efi
do
  if [ -f "$dir/teslausb_setup_variables.conf" ]
  then
    CONF="$dir/teslausb_setup_variables.conf"
    LOG_DIR="$dir"
    break
  fi
done

if [ -z "$CONF" ]
then
  # Not an error: a card prepared with prepare-boot-partition.sh has its config on the
  # root filesystem already, and nothing here needs doing.
  echo "teslausb pre-setup: no teslausb_setup_variables.conf on the boot partition, nothing to do"
  exit 0
fi

log "found $CONF"

# --- find the script that knows how to apply it ------------------------------
# It has to be the whole source tree, not just the one script. prepare-boot-partition.sh
# works out where the repository is from its own location and installs files from it, so
# run on its own out of some staging directory it would look for the bootstrap next door
# in DietPi's /boot/dietpi and fail. The image stages the released source for exactly this,
# which also means the device installs the version on the tin rather than whatever the
# branch happens to be today.
PREPARE=""
if [ -f /boot/teslausb-local/repo.tar ]
then
  staged=$(mktemp -d)
  if tar -xf /boot/teslausb-local/repo.tar -C "$staged" 2> /dev/null &&
     [ -f "$staged/tools/prepare-boot-partition.sh" ] &&
     [ -f "$staged/dietpi/Automation_Custom_Script.sh" ]
  then
    PREPARE="$staged/tools/prepare-boot-partition.sh"
    chmod +x "$PREPARE" 2> /dev/null
  fi
fi

if [ -z "$PREPARE" ]
then
  log "WARNING: no prepare-boot-partition.sh in the image, so wifi cannot be set up here."
  log "WARNING: DietPi will try to bring up the network with whatever it was flashed with."
  exit 0
fi

# --- apply it ----------------------------------------------------------------
# /boot is DietPi's own boot directory, which is where its settings have to land. The
# script recognises that by the dietpi directory beside dietpi.txt and writes both
# DietPi's files and teslausb's to it.
if "$PREPARE" /boot "$CONF" >> "$LOG_DIR/$BOOT_LOG" 2>&1
then
  log "applied the settings from teslausb_setup_variables.conf"
  if [ -f /boot/dietpi-wifi.txt ] && grep -q "^aWIFI_SSID\[0\]='.\+'" /boot/dietpi-wifi.txt
  then
    log "wifi credentials are in place for DietPi's own network setup"
  else
    log "WARNING: no wifi credentials were written. Set SSID and WIFIPASS in"
    log "WARNING: teslausb_setup_variables.conf on the boot partition, or the device"
    log "WARNING: will boot with no network and cannot be reached."
  fi
else
  log "WARNING: could not apply teslausb_setup_variables.conf; see $BOOT_LOG."
  log "WARNING: continuing the boot regardless."
fi

exit 0
