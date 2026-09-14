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
# Which directory does the running system actually read?
#
# On the Raspberry Pi images it is not the partition you can see from a PC. Those
# use the Debian layout, where the FAT partition is mounted at /boot/firmware and
# /boot lives on the root filesystem, and DietPi reads /boot/dietpi.txt,
# /boot/dietpi-wifi.txt and /boot/Automation_Custom_Script.sh from there. The FAT
# partition carries its own copies, but nothing reads them, so configuring only
# what a PC can see leaves a device that boots into an interactive DietPi with no
# network. That happened on real hardware; the single-partition images used for
# testing hid it, because there /boot is on the root filesystem already.
#
# So: if the given partition carries DietPi's own scripts, it is the real thing.
# Otherwise it is a firmware partition, and the root filesystem beside it has to
# be mounted to put the config where it will be read.
# ---------------------------------------------------------------------------
TARGET="$BOOT"
ROOTFS_MOUNT=""

cleanup_rootfs () {
  [ -n "$ROOTFS_MOUNT" ] || return 0
  sync
  umount "$ROOTFS_MOUNT" 2> /dev/null || true
  rmdir "$ROOTFS_MOUNT" 2> /dev/null || true
}
trap cleanup_rootfs EXIT

if [ ! -d "$BOOT/dietpi" ]
then
  log "this is a firmware partition; DietPi reads its config from the root filesystem"
  boot_source=$(findmnt -no SOURCE --target "$BOOT") || \
    die "cannot work out which device $BOOT is on"
  case "$boot_source" in
    *[0-9]p[0-9]) rootfs_dev="${boot_source%p*}p$(( ${boot_source##*p} + 1 ))" ;;
    *[0-9])       rootfs_dev="${boot_source%[0-9]}$(( ${boot_source##*[a-z]} + 1 ))" ;;
    *) die "cannot work out the root partition next to $boot_source" ;;
  esac
  [ -b "$rootfs_dev" ] || die "expected the root filesystem on $rootfs_dev, which does not exist"

  if existing=$(findmnt -no TARGET "$rootfs_dev" 2> /dev/null) && [ -n "$existing" ]
  then
    log "using the root filesystem already mounted at $existing"
    TARGET="$existing/boot"
  else
    ROOTFS_MOUNT=$(mktemp -d)
    mount "$rootfs_dev" "$ROOTFS_MOUNT" || \
      die "could not mount $rootfs_dev. This needs root, and a Linux machine, because
     the root filesystem is ext4."
    log "mounted $rootfs_dev to write the config where DietPi reads it"
    TARGET="$ROOTFS_MOUNT/boot"
  fi

  [ -f "$TARGET/dietpi.txt" ] || die "$TARGET has no dietpi.txt, so this is not a DietPi root filesystem"
fi

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
TIMEZONE_WANTED=$(conf_value TESLAUSB_TIMEZONE "")
MDNS_WANTED=$(conf_value TESLAUSB_MDNS_NAME "")

# Both are DNS labels: letters, digits and hyphens, not starting or ending with a
# hyphen, at most 63 characters. Catching this here means being told now, rather
# than finding out that a device in a car never appeared on the network.
for pair in "TESLAUSB_HOSTNAME:$HOSTNAME_WANTED" "TESLAUSB_MDNS_NAME:$MDNS_WANTED"
do
  name=${pair#*:}
  [ -n "$name" ] || continue
  if ! [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
  then
    echo "FATAL: ${pair%%:*} '$name' is not a usable name." >&2
    echo "       Use letters, digits and hyphens only, not starting or ending with a" >&2
    echo "       hyphen, at most 63 characters." >&2
    exit 1
  fi
done
OS_PASSWORD=$(conf_value OS_PASSWORD "")

# ---------------------------------------------------------------------------
# Copy the teslausb pieces
# ---------------------------------------------------------------------------
log "installing teslausb_setup_variables.conf"
install -m 600 "$CONF" "$TARGET/teslausb_setup_variables.conf"

log "installing Automation_Custom_Script.sh"
install -m 755 "$REPO/dietpi/Automation_Custom_Script.sh" "$TARGET/Automation_Custom_Script.sh"

# ---------------------------------------------------------------------------
# Update dietpi.txt in place. Only the keys teslausb depends on are touched, so
# everything else the user configured is left alone.
# ---------------------------------------------------------------------------
set_dietpi_key () {
  local key="$1" value="$2" file="$TARGET/dietpi.txt"
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

# The images are set to UTC, which makes every timestamp in the setup log, the
# archive log and the watchdog log hours away from the clock of whoever is reading
# them.
if [ -n "$TIMEZONE_WANTED" ]
then
  set_dietpi_key AUTO_SETUP_TIMEZONE "$TIMEZONE_WANTED"
fi

# The login password for root and the dietpi user. The prebuilt Raspberry Pi OS
# image shipped with a known default (user pi, password raspberry); DietPi's
# equivalent is this key, and leaving it at DietPi's default is just as weak.
if [ -n "$OS_PASSWORD" ]
then
  set_dietpi_key AUTO_SETUP_GLOBAL_PASSWORD "$OS_PASSWORD"
else
  current_pw=$(sed -n '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/{s/^[^=]*=//p;q}' "$TARGET/dietpi.txt")
  if [ "$current_pw" = "dietpi" ]
  then
    log "WARNING: the login password is still DietPi's default ('dietpi')."
    log "         Set OS_PASSWORD in your config, or edit AUTO_SETUP_GLOBAL_PASSWORD"
    log "         in dietpi.txt, before putting this device on your network."
  fi
fi

# The prebuilt Raspberry Pi OS image had SSH enabled out of the box (pi-gen
# touched /boot/ssh), and a device that lives in a car has no other way in.
#
# Mind the values, which are not intuitive: 0 means none/custom, -1 is Dropbear
# and -2 is OpenSSH. DietPi images ship with 0, so an unattended first boot
# actually REMOVES the pre-installed Dropbear and leaves the device unreachable.
#
# teslausb asks for OpenSSH, always. Its rsync archive backend shells out to ssh,
# which Dropbear does not provide, so Dropbear is not a working choice here even
# though DietPi recommends it.
ssh_index=$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' "$TARGET/dietpi.txt")
if [ "$ssh_index" = -1 ]
then
  log "dietpi.txt: asking for OpenSSH instead of Dropbear, which cannot serve the rsync archive path"
fi
set_dietpi_key AUTO_SETUP_SSH_SERVER_INDEX -2

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
  cat > "$TARGET/dietpi-wifi.txt" <<EOF
aWIFI_SSID[0]='${SSID}'
aWIFI_KEY[0]='${WIFIPASS}'
aWIFI_KEYMGR[0]='WPA-PSK'
EOF
  chmod 600 "$TARGET/dietpi-wifi.txt"
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
# ---------------------------------------------------------------------------
# Start the first run without a keyboard.
#
# DietPi's first run is triggered by a login shell: /etc/bashrc.d/dietpi.bash hands
# over to dietpi-login. With no keyboard attached nothing ever logs in, so the
# device waits at "press Enter to login" forever, which means no first run,
# therefore no wifi, therefore no ssh, therefore no way to log in. DietPi's own
# autologin setting cannot break that circle: as its dietpi.txt says, it "will be
# effective on 2nd boot, after first run update and installs have been done".
#
# A plain systemd drop-in does work on the first boot. It is also deliberately not
# named dietpi-autologin.conf, because DietPi deletes that file when a first run
# fails and falls back to an interactive retry, which is exactly when a device in a
# car still needs to be able to log itself in.
# ---------------------------------------------------------------------------
rootfs_root="$(dirname "$TARGET")"
if [ -d "$rootfs_root/etc/systemd/system" ]
then
  log "setting up console autologin so the first run starts without a keyboard"
  mkdir -p "$rootfs_root/etc/systemd/system/getty@tty1.service.d"
  cat > "$rootfs_root/etc/systemd/system/getty@tty1.service.d/teslausb-autologin.conf" <<'EOF'
# Written by teslausb setup.
#
# DietPi's first run only starts once something logs in, and a device in a car has
# no keyboard. Without this it waits at the login prompt forever, never brings up
# wifi, and can never be reached.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
else
  log "WARNING: could not reach the root filesystem, so console autologin is not set up."
  log "WARNING: without a keyboard, DietPi's first run may never start."
fi

# ---------------------------------------------------------------------------
# Keep DietPi from expanding the root partition over the whole card.
#
# teslausb puts its backing files in unpartitioned space and refuses to install with
# less than 32GiB of it. DietPi expands the root filesystem to fill the card on first
# boot, which leaves none, and setup stops after printing a one-partition table.
# /dietpi_skip_partition_resize is DietPi's own marker for skipping that.
# ---------------------------------------------------------------------------
if [ -d "$rootfs_root/etc" ]
then
  if [ ! -e "$rootfs_root/dietpi_skip_partition_resize" ]
  then
    log "keeping DietPi from expanding the root partition over the free space"
    : > "$rootfs_root/dietpi_skip_partition_resize"
  fi

  # Skipping the expansion is only half of it. The images ship a root filesystem of
  # a few hundred megabytes, and DietPi's own apt upgrade does not fit in that: it
  # runs out of space part way through and the first run fails.
  root_kb=$(df -k --output=size "$rootfs_root" 2> /dev/null | tail -1 | tr -d ' ')
  if [ -n "${root_kb:-}" ] && [ "$root_kb" -lt 3000000 ]
  then
    log "WARNING: the root filesystem is only $(( root_kb / 1024 ))MB, and expansion has"
    log "WARNING: just been disabled to leave room for teslausb. DietPi's own first run"
    log "WARNING: needs more than that for its apt upgrade. Grow the root partition to"
    log "WARNING: about 8GB before booting, leaving its start sector alone, for example:"
    log "WARNING:   printf '%s,%s\\n' START \$(( 8 * 1024 * 1024 * 2 )) | sfdisk --force -N2 /dev/DEVICE"
    log "WARNING:   e2fsck -fp /dev/DEVICEp2 && resize2fs /dev/DEVICEp2"
  fi
fi

# ---------------------------------------------------------------------------
# Anything to seed into the cam drive's root.
#
# Tesla reads LockChime.wav from the root of the drive for its custom lock sound,
# and a Boombox folder from the same place. Those are just files on the drive, so a
# rebuilt card loses them unless they are carried across. Put them in a
# teslausb-cam-root directory next to your config and setup copies them onto the cam
# drive when it creates it.
# ---------------------------------------------------------------------------
conf_dir="$(cd "$(dirname "$CONF")" && pwd)"
if [ -d "$conf_dir/teslausb-cam-root" ]
then
  log "staging $(find "$conf_dir/teslausb-cam-root" -type f | wc -l) file(s) for the cam drive root"
  rm -rf "$TARGET/teslausb-cam-root"
  cp -r "$conf_dir/teslausb-cam-root" "$TARGET/teslausb-cam-root"
fi

echo
echo "Log in as 'root' or 'dietpi' (DietPi has no 'pi' user), with the password"
echo "from AUTO_SETUP_GLOBAL_PASSWORD in dietpi.txt."
