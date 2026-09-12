#!/bin/bash
#
# prepare-boot-partition.sh - configure everything before the first boot.
#
# On Raspberry Pi OS, teslausb was configured by dropping
# teslausb_setup_variables.conf onto the boot partition of a freshly flashed
# card. DietPi works the same way, except that DietPi has its own pre-boot
# config files: it brings up the network and updates itself before any teslausb
# code exists, so the wifi credentials have to be in DietPi's files rather than
# only in teslausb's.
#
# Rather than making you edit several files, this script takes your single
# teslausb_setup_variables.conf and writes everything the first boot needs onto
# the boot partition:
#
#   teslausb_setup_variables.conf   your config, as before
#   Automation_Custom_Script.sh     the teslausb bootstrap DietPi runs
#   dietpi.txt                      updated in place: unattended, wifi, hostname
#   dietpi-wifi.txt                 SSID and passphrase from your config
#
# After running it, eject the card, boot the device, and setup proceeds on its
# own exactly as it used to.
#
# Usage:
#   tools/prepare-boot-partition.sh <boot-partition> [teslausb_setup_variables.conf]
#
# Example:
#   sudo tools/prepare-boot-partition.sh /media/me/bootfs ~/teslausb_setup_variables.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO="$SCRIPT_DIR/.."

readonly BOOT="${1:-}"
readonly CONF="${2:-$REPO/dietpi/teslausb_setup_variables.conf.sample}"

die () { echo "STOP: $*" >&2; exit 1; }
log () { echo "==> $*"; }

[ -n "$BOOT" ] || die "usage: $0 <boot-partition> [teslausb_setup_variables.conf]"
[ -d "$BOOT" ] || die "$BOOT is not a directory. Mount the boot partition first."
[ -f "$CONF" ] || die "$CONF does not exist"

# A DietPi boot partition always has dietpi.txt on it. Refuse to touch anything
# else, so a wrong path cannot scribble over the user's own files.
[ -f "$BOOT/dietpi.txt" ] || \
  die "$BOOT does not look like a DietPi boot partition (no dietpi.txt).
     Flash a DietPi image from https://dietpi.com/#download first."

# ---------------------------------------------------------------------------
# Read the teslausb config. It is sourced in a subshell so a broken file cannot
# affect this script, and only the values needed here are pulled back out.
# ---------------------------------------------------------------------------
if ! ( set -eu; # shellcheck disable=SC1090
       source "$CONF" ) &> /tmp/prepare-boot-check.out
then
  echo "$CONF has an error in it:" >&2
  cat /tmp/prepare-boot-check.out >&2
  exit 1
fi

# Pull out one value at a time, each in its own subshell, so nothing in the
# config can leak into this script.
conf_value () {
  # shellcheck disable=SC1090
  ( set +u; source "$CONF" 2> /dev/null; printf '%s' "${!1:-$2}" )
}

SSID=$(conf_value SSID "")
WIFIPASS=$(conf_value WIFIPASS "")
WIFI_COUNTRY=$(conf_value WIFI_COUNTRY US)
HOSTNAME_WANTED=$(conf_value TESLAUSB_HOSTNAME teslausb)
OS_PASSWORD=$(conf_value OS_PASSWORD "")

# ---------------------------------------------------------------------------
# Copy the teslausb pieces
# ---------------------------------------------------------------------------
log "installing teslausb_setup_variables.conf"
install -m 600 "$CONF" "$BOOT/teslausb_setup_variables.conf"

log "installing Automation_Custom_Script.sh"
install -m 755 "$REPO/dietpi/Automation_Custom_Script.sh" "$BOOT/Automation_Custom_Script.sh"

# ---------------------------------------------------------------------------
# Update dietpi.txt in place. Only the keys teslausb depends on are touched, so
# everything else the user configured is left alone.
# ---------------------------------------------------------------------------
set_dietpi_key () {
  local key="$1" value="$2" file="$BOOT/dietpi.txt"
  if grep -q "^${key}=" "$file"
  then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
  log "dietpi.txt: ${key}=${value}"
}

set_dietpi_key AUTO_SETUP_AUTOMATED 1
set_dietpi_key AUTO_SETUP_CUSTOM_SCRIPT_EXEC 1
set_dietpi_key AUTO_SETUP_NET_HOSTNAME "$HOSTNAME_WANTED"

# The login password for root and the dietpi user. The prebuilt Raspberry Pi OS
# image shipped with a known default (user pi, password raspberry); DietPi's
# equivalent is this key, and leaving it at DietPi's default is just as weak.
if [ -n "$OS_PASSWORD" ]
then
  set_dietpi_key AUTO_SETUP_GLOBAL_PASSWORD "$OS_PASSWORD"
else
  current_pw=$(sed -n '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/{s/^[^=]*=//p;q}' "$BOOT/dietpi.txt")
  if [ "$current_pw" = "dietpi" ]
  then
    log "WARNING: the login password is still DietPi's default ('dietpi')."
    log "         Set OS_PASSWORD in your config, or edit AUTO_SETUP_GLOBAL_PASSWORD"
    log "         in dietpi.txt, before putting this device on your network."
  fi
fi

# The prebuilt Raspberry Pi OS image had SSH enabled out of the box (pi-gen
# touched /boot/ssh). Keep that guarantee: -1 would disable SSH entirely and
# leave a headless device unreachable.
ssh_index=$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' "$BOOT/dietpi.txt")
if [ -z "$ssh_index" ] || [ "$ssh_index" = "-1" ]
then
  # missing or explicitly disabled: a headless device in a car needs SSH
  set_dietpi_key AUTO_SETUP_SSH_SERVER_INDEX 0
else
  log "dietpi.txt: leaving AUTO_SETUP_SSH_SERVER_INDEX as it is ($ssh_index)"
fi

# ---------------------------------------------------------------------------
# Wifi, if the config asks for it. This is what makes a wifi-only board work on
# the very first boot: DietPi needs the network before teslausb exists, so the
# credentials have to be here rather than only in the teslausb config.
# ---------------------------------------------------------------------------
if [ -n "$SSID" ] && [ -n "$WIFIPASS" ]
then
  set_dietpi_key AUTO_SETUP_NET_WIFI_ENABLED 1
  set_dietpi_key AUTO_SETUP_NET_WIFI_COUNTRY_CODE "$WIFI_COUNTRY"
  log "writing dietpi-wifi.txt for '$SSID'"
  cat > "$BOOT/dietpi-wifi.txt" <<EOF
aWIFI_SSID[0]='${SSID}'
aWIFI_KEY[0]='${WIFIPASS}'
aWIFI_KEYMGR[0]='WPA-PSK'
EOF
  chmod 600 "$BOOT/dietpi-wifi.txt"
else
  log "WARNING: no SSID/WIFIPASS in the config."
  log "WARNING: this device will have no network on first boot, and DietPi needs one"
  log "WARNING: to finish its own setup before teslausb is installed. A Pi in a car"
  log "WARNING: has no ethernet, so unless you are setting this up on a desk with a"
  log "WARNING: wired connection, set SSID and WIFIPASS in your config and re-run."
fi

sync

echo
echo "Done. $BOOT is ready:"
echo "  - eject the card and boot the device"
echo "  - DietPi does its own first-boot setup unattended, then starts teslausb setup"
echo "  - progress is logged to teslausb-headless-setup.log on this partition"
echo
echo "Log in as 'root' or 'dietpi' (DietPi has no 'pi' user), with the password"
echo "from AUTO_SETUP_GLOBAL_PASSWORD in dietpi.txt."
