#!/bin/bash
#
# Builds a flashable teslausb image from an official DietPi image.
#
# Usage: tools/build-image.sh <board> <distro> [output.img.xz]
#   e.g. tools/build-image.sh RPi234-ARMv8 Bookworm
#
# What comes out is a DietPi image with teslausb's bootstrap already on it and one file to
# edit: teslausb_setup_variables.conf, on the boot partition, which is the only partition
# Windows and macOS both mount. Flash it, edit that file, boot it, and the device sets
# itself up over wifi with no keyboard and no screen.
#
# Nothing here needs root or a loop device: the ext4 root filesystem is written with
# debugfs and the FAT boot partition with mtools, both of which work on a partition image
# carved out of the disk image with dd. That means it runs the same way on a workstation
# and on a CI runner, and cannot accidentally touch the host's own filesystems.
#
# The image stages the repository it was built from rather than having the device download
# the latest source at first boot, so a release installs the version it says it does.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly BOARD="${1:?usage: build-image.sh <board> <distro> [output]}"
readonly DISTRO="${2:?usage: build-image.sh <board> <distro> [output]}"
readonly CACHE_DIR="${DIETPI_CACHE_DIR:-${TMPDIR:-/tmp}/teslausb-image-cache}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/teslausb-image.XXXXXX")"
readonly WORK_DIR
readonly SOURCE_IMAGE="DietPi_${BOARD}-${DISTRO}.img.xz"
readonly SOURCE_URL="https://dietpi.com/downloads/images/${SOURCE_IMAGE}"
OUT="${3:-teslausb-${BOARD}-${DISTRO}.img.xz}"
readonly OUT

log () { echo "==> $*"; }
die () { echo "FATAL: $*" >&2; exit 1; }

cleanup () { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

for tool in curl xz sfdisk dd debugfs mcopy mmd mtype sha256sum tar
do
  command -v "$tool" > /dev/null || die "$tool is required (mcopy/mmd/mtype come from mtools)"
done

mkdir -p "$CACHE_DIR"

# --- fetch and verify the DietPi image ---------------------------------------
# DietPi publishes a sha256 beside each image. An image that fails it is not built on:
# every device flashed from the result would carry the damage.
if [ ! -s "$CACHE_DIR/$SOURCE_IMAGE" ]
then
  log "downloading $SOURCE_IMAGE"
  curl -fsSL --retry 3 -o "$CACHE_DIR/$SOURCE_IMAGE.part" "$SOURCE_URL" ||
    die "could not download $SOURCE_URL"
  mv "$CACHE_DIR/$SOURCE_IMAGE.part" "$CACHE_DIR/$SOURCE_IMAGE"
else
  log "using the cached $SOURCE_IMAGE"
fi

log "verifying sha256"
if curl -fsSL --retry 3 -o "$WORK_DIR/expected.sha256" "$SOURCE_URL.sha256" 2> /dev/null
then
  expected=$(tr -d '\r' < "$WORK_DIR/expected.sha256" | awk '{print $1; exit}')
  actual=$(sha256sum "$CACHE_DIR/$SOURCE_IMAGE" | awk '{print $1}')
  [ "$expected" = "$actual" ] || die "sha256 mismatch on $SOURCE_IMAGE: expected $expected, got $actual"
  log "sha256 matches DietPi's published checksum"
else
  log "WARNING: DietPi published no checksum for this image, continuing unverified"
fi

log "decompressing"
xz -dc "$CACHE_DIR/$SOURCE_IMAGE" > "$WORK_DIR/disk.img"

# --- locate the partitions ---------------------------------------------------
# Read the table rather than assuming an order: DietPi's own images differ, with the FAT
# partition first on Raspberry Pi images and last, labelled DIETPISETUP, on some others.
# "Units: sectors of 1 * 512 = 512 bytes", so take the total, not the first number in it.
sector_size=$(sfdisk -l "$WORK_DIR/disk.img" 2> /dev/null |
  sed -n 's/^Units:.*= \([0-9][0-9]*\) bytes.*/\1/p' | head -1)
sector_size=${sector_size:-512}
log "sector size $sector_size bytes"

boot_start=""; boot_sectors=""; root_start=""; root_sectors=""; root_part=""; last_part=""
while read -r line
do
  case "$line" in
    *"type=c"*|*"type=b"*|*"type=e"*|*"type=EF"*|*"type=0c"*|*"type=0b"*)
      [ -n "$boot_start" ] && continue
      boot_start=$(printf '%s' "$line" | sed -n 's/.*start=[[:blank:]]*\([0-9][0-9]*\).*/\1/p')
      boot_sectors=$(printf '%s' "$line" | sed -n 's/.*size=[[:blank:]]*\([0-9][0-9]*\).*/\1/p')
      ;;
    *"type=83"*)
      [ -n "$root_start" ] && continue
      root_start=$(printf '%s' "$line" | sed -n 's/.*start=[[:blank:]]*\([0-9][0-9]*\).*/\1/p')
      root_sectors=$(printf '%s' "$line" | sed -n 's/.*size=[[:blank:]]*\([0-9][0-9]*\).*/\1/p')
      root_part=$(printf '%s' "$line" | sed -n 's|^.*[^0-9]\([0-9][0-9]*\)[[:blank:]]*:.*|\1|p')
      ;;
  esac
done < <(sfdisk -d "$WORK_DIR/disk.img")
last_part=$(sfdisk -d "$WORK_DIR/disk.img" | sed -n 's|^.*[^0-9]\([0-9][0-9]*\)[[:blank:]]*:.*|\1|p' | tail -1)

[ -n "$root_start" ] || die "no ext4 root partition in $SOURCE_IMAGE"
log "root partition at sector $root_start, $root_sectors sectors"
if [ -n "$boot_start" ]
then
  log "boot partition at sector $boot_start, $boot_sectors sectors"
else
  log "no FAT boot partition; the config will go on the root filesystem's /boot"
fi

dd if="$WORK_DIR/disk.img" of="$WORK_DIR/root.img" bs="$sector_size" \
  skip="$root_start" count="$root_sectors" status=none
if [ -n "$boot_start" ]
then
  dd if="$WORK_DIR/disk.img" of="$WORK_DIR/boot.img" bs="$sector_size" \
    skip="$boot_start" count="$boot_sectors" status=none
fi

# --- give the root filesystem room ------------------------------------------
# DietPi ships a root filesystem with about 140MB free, which is too small for two
# reasons: there is not enough room to stage teslausb's own source in it, and DietPi's
# updater needs more than that later, which is why setup warns below 3GB. Growing it here
# means one less thing to do by hand to a freshly flashed card.
#
# This is only safe because the root partition is the last one, so the space is simply
# added on the end. Refuse rather than corrupt anything if that is ever not true.
readonly ROOT_SIZE_MB="${ROOT_SIZE_MB:-4096}"
want_sectors=$(( ROOT_SIZE_MB * 1024 * 1024 / sector_size ))
if [ "$want_sectors" -gt "$root_sectors" ]
then
  [ "$root_part" = "$last_part" ] ||
    die "the root partition is not the last one, so it cannot be grown safely"
  log "growing the root filesystem to ${ROOT_SIZE_MB}MB (it ships with $(( root_sectors * sector_size / 1024 / 1024 ))MB)"
  e2fsck -fp "$WORK_DIR/root.img" > /dev/null 2>&1 || true
  truncate -s "$(( want_sectors * sector_size ))" "$WORK_DIR/root.img"
  resize2fs "$WORK_DIR/root.img" > /dev/null 2>&1 ||
    die "could not grow the root filesystem"
  truncate -s "$(( (root_start + want_sectors) * sector_size ))" "$WORK_DIR/disk.img"
  printf ',%s\n' "$want_sectors" |
    sfdisk --force -N"$root_part" "$WORK_DIR/disk.img" > /dev/null 2>&1 ||
    die "could not grow the root partition"
  root_sectors=$want_sectors
  free_mb=$(( $(dumpe2fs -h "$WORK_DIR/root.img" 2> /dev/null |
    sed -n 's/^Free blocks:[[:blank:]]*//p') * 4 / 1024 ))
  log "root filesystem now has ${free_mb}MB free"
fi

# --- stage the released source ----------------------------------------------
# git archive rather than tar of the working tree: only tracked files, so a stray build
# artifact in the checkout cannot end up inside the image. A plain tar of "." put a 180MB
# copy of a previously built image in there.
revision=$(git -C "$REPO_DIR" rev-parse --short HEAD 2> /dev/null || echo unknown)
log "staging the repository at $revision"
git -C "$REPO_DIR" archive --format=tar --prefix=./ HEAD > "$WORK_DIR/repo.tar" ||
  die "could not archive the repository; build from a git checkout"
log "staged source is $(( $(stat -c %s "$WORK_DIR/repo.tar") / 1024 ))KB"

# debugfs reports failures on stdout and still exits 0, so its output has to be read.
# Silently ignoring it hid a filesystem with no room left in it.
ext4_write () {
  local src="$1" dest="$2" out
  debugfs -w -R "rm ${dest#/}" "$WORK_DIR/root.img" &> /dev/null || true
  out=$(debugfs -w -R "write ${src} ${dest#/}" "$WORK_DIR/root.img" 2>&1 |
    grep -viE "^debugfs [0-9]|^Allocated inode:|^$" || true)
  [ -z "$out" ] || die "could not write $dest into the image: $out"
}

ext4_mkdir () {
  local out
  out=$(debugfs -w -R "mkdir ${1#/}" "$WORK_DIR/root.img" 2>&1 |
    grep -viE "^debugfs [0-9]|^Allocated inode:|already exists|^$" || true)
  [ -z "$out" ] || die "could not create $1 in the image: $out"
}

ext4_dump () {
  debugfs -R "dump ${1#/} $2" "$WORK_DIR/root.img" 2> /dev/null || true
}

# --- DietPi's own settings, on the root filesystem where it reads them -------
log "configuring dietpi.txt"
ext4_dump /boot/dietpi.txt "$WORK_DIR/dietpi.txt"
[ -s "$WORK_DIR/dietpi.txt" ] || die "no /boot/dietpi.txt in the image"

set_key () {
  local key="$1" value="$2"
  if grep -qE "^[[:blank:]#]*${key}=" "$WORK_DIR/dietpi.txt"
  then
    sed -i -E "s|^[[:blank:]#]*${key}=.*|${key}=${value}|" "$WORK_DIR/dietpi.txt"
  else
    printf '%s=%s\n' "$key" "$value" >> "$WORK_DIR/dietpi.txt"
  fi
  log "dietpi.txt: ${key}=${value}"
}

# Unattended, run our bootstrap, and OpenSSH rather than Dropbear, which cannot serve the
# rsync archive path. Everything else is left for the user's config to set at first boot.
set_key AUTO_SETUP_AUTOMATED 1
set_key AUTO_SETUP_CUSTOM_SCRIPT_EXEC 1
set_key AUTO_SETUP_SSH_SERVER_INDEX -2
set_key SURVEY_OPTED_IN 0
ext4_write "$WORK_DIR/dietpi.txt" /boot/dietpi.txt

log "installing the bootstrap and the pre-setup hook"
ext4_write "$REPO_DIR/dietpi/Automation_Custom_Script.sh" /boot/Automation_Custom_Script.sh
ext4_write "$REPO_DIR/dietpi/Automation_Custom_PreScript.sh" /boot/Automation_Custom_PreScript.sh
debugfs -w -R "sif /boot/Automation_Custom_Script.sh mode 0100755" "$WORK_DIR/root.img" &> /dev/null || true
debugfs -w -R "sif /boot/Automation_Custom_PreScript.sh mode 0100755" "$WORK_DIR/root.img" &> /dev/null || true

log "staging the source so first boot installs this version, not the latest"
ext4_mkdir /boot/teslausb-local
ext4_write "$WORK_DIR/repo.tar" /boot/teslausb-local/repo.tar
ext4_write "$REPO_DIR/setup/pi/first-boot.sh" /boot/teslausb-local/first-boot.sh
debugfs -w -R "sif /boot/teslausb-local/first-boot.sh mode 0100755" "$WORK_DIR/root.img" &> /dev/null || true
ext4_write "$REPO_DIR/setup/pi/teslausb-setup.service" /boot/teslausb-local/teslausb-setup.service

# DietPi's first run only starts once something logs in, and a device in a car has no
# keyboard. Deliberately not named dietpi-autologin.conf, which DietPi deletes when its
# first run fails.
log "setting up console autologin, so the first run starts without a keyboard"
cat > "$WORK_DIR/autologin.conf" << 'UNIT'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
UNIT
ext4_mkdir /etc/systemd/system/getty@tty1.service.d
ext4_write "$WORK_DIR/autologin.conf" /etc/systemd/system/getty@tty1.service.d/teslausb-autologin.conf

# Without this DietPi expands the root filesystem over the whole card on first boot and
# there is nowhere left for the recordings to go.
log "keeping DietPi from expanding the root over the card"
: > "$WORK_DIR/marker"
ext4_write "$WORK_DIR/marker" /dietpi_skip_partition_resize

# --- the one file the user edits, on the partition every OS can mount -------
if [ -n "$boot_start" ]
then
  log "putting teslausb_setup_variables.conf on the boot partition"
  mcopy -o -i "$WORK_DIR/boot.img" \
    "$REPO_DIR/dietpi/teslausb_setup_variables.conf.sample" \
    ::teslausb_setup_variables.conf
  mmd -i "$WORK_DIR/boot.img" ::teslausb-cam-root 2> /dev/null || true

  cat > "$WORK_DIR/README.txt" << 'README'
teslausb
========

Edit teslausb_setup_variables.conf on this partition before the first boot. At a minimum
set SSID and WIFIPASS to your wifi network, and set OS_PASSWORD, or the device will boot
with DietPi's default password on your network.

Then put the card in the device and power it on. Everything else is unattended: DietPi
sets itself up, joins the wifi, and teslausb partitions the card and starts recording.
It reboots a few times on the way and takes a while on the first boot.

Progress is logged to teslausb-headless-setup.log on this partition, so if something goes
wrong you can put the card back in a computer and read what happened.

Anything you drop into the teslausb-cam-root folder here is copied to the root of the
drive the car sees, which is where a LockChime.wav or a Boombox folder goes.

Setup instructions: https://github.com/nich227/teslausb/blob/main-dev/doc/OneStepSetup.md
README
  mcopy -o -i "$WORK_DIR/boot.img" "$WORK_DIR/README.txt" ::README.txt

  # A monitor plugged into one of these is almost always a sign something went wrong, and
  # with no keyboard attached nothing can wake a display that has gone to sleep.
  if mtype -i "$WORK_DIR/boot.img" ::config.txt > "$WORK_DIR/config.txt" 2> /dev/null
  then
    if grep -qE '^[[:blank:]]*hdmi_blanking=' "$WORK_DIR/config.txt"
    then
      sed -i -E 's|^[[:blank:]]*hdmi_blanking=.*|hdmi_blanking=0|' "$WORK_DIR/config.txt"
    else
      printf 'hdmi_blanking=0\n' >> "$WORK_DIR/config.txt"
    fi
    mcopy -o -i "$WORK_DIR/boot.img" "$WORK_DIR/config.txt" ::config.txt
    log "config.txt: hdmi_blanking=0, so an attached display does not go to sleep"
  fi
else
  log "putting teslausb_setup_variables.conf on the root filesystem's /boot"
  ext4_write "$REPO_DIR/dietpi/teslausb_setup_variables.conf.sample" /boot/teslausb_setup_variables.conf
fi

# --- put the partitions back and compress ------------------------------------
log "writing the partitions back"
dd if="$WORK_DIR/root.img" of="$WORK_DIR/disk.img" bs="$sector_size" \
  seek="$root_start" conv=notrunc status=none
if [ -n "$boot_start" ]
then
  dd if="$WORK_DIR/boot.img" of="$WORK_DIR/disk.img" bs="$sector_size" \
    seek="$boot_start" conv=notrunc status=none
fi

log "compressing to $OUT"
xz -T0 -6 -c "$WORK_DIR/disk.img" > "$OUT"

log "done"
printf '    image:  %s\n' "$OUT"
printf '    size:   %s MB\n' "$(( $(stat -c %s "$OUT") / 1024 / 1024 ))"
printf '    sha256: %s\n' "$(sha256sum "$OUT" | awk '{print $1}')"
