#!/bin/bash
#
# Runs INSIDE a container (see run-vm-test.sh). Prepares a bootable DietPi VM
# disk image with the teslausb boot files already on it, exactly as if you had
# flashed a card and run tools/prepare-boot-partition.sh against it.
#
# Everything is done with debugfs rather than by mounting, so no loop device and
# no privileges on the host are needed.
#
# Inputs (environment):
#   IMAGE_NAME   the DietPi VM image in /cache, e.g. DietPi_VM-x86_64-Bookworm.img.xz
#   CONF         teslausb config to install, path inside the container
#   GROW_GB      how much free space to add for the backing files partition
# Output:
#   /cache/teslausb-vm.img

set -euo pipefail

: "${IMAGE_NAME:?}"
: "${CONF:=/repo/tests/vm/vm-test.conf}"
: "${GROW_GB:=4}"

readonly WORK=/tmp/work.img
readonly PART=/tmp/root.img
readonly STAGING=/tmp/boot-staging

log () { printf '    [inject] %s\n' "$*"; }

apt-get -qq update > /dev/null
apt-get -qq install -y --no-install-recommends xz-utils e2fsprogs fdisk > /dev/null

log "decompressing $IMAGE_NAME"
xz -dc "/cache/$IMAGE_NAME" > "$WORK"

# Room for the backing files partition teslausb creates later.
log "growing the image by ${GROW_GB}G"
truncate -s "+${GROW_GB}G" "$WORK"

# --- carve out the root partition -----------------------------------------
start=$(sfdisk -d "$WORK" | sed -n 's/.*start=[[:blank:]]*\([0-9][0-9]*\).*type=83.*/\1/p' | head -1)
size=$(sfdisk -d "$WORK" | sed -n 's/.*size=[[:blank:]]*\([0-9][0-9]*\).*type=83.*/\1/p' | head -1)
[ -n "$start" ] && [ -n "$size" ] || { echo "could not find the root partition" >&2; exit 1; }
log "root partition at sector $start, $size sectors"
dd if="$WORK" of="$PART" bs=512 skip="$start" count="$size" status=none

# --- pull out the files prepare-boot-partition.sh needs to see ------------
mkdir -p "$STAGING"
debugfs -R "dump /boot/dietpi.txt $STAGING/dietpi.txt" "$PART" 2> /dev/null
[ -s "$STAGING/dietpi.txt" ] || { echo "no /boot/dietpi.txt in the image" >&2; exit 1; }

# --- run the real thing ---------------------------------------------------
# This is the same script a user runs against a freshly flashed card, which is
# the point: the VM tests that script's output rather than a copy of it.
log "running tools/prepare-boot-partition.sh"
/repo/tools/prepare-boot-partition.sh "$STAGING" "$CONF" | sed 's/^/    /'

# --- a serial console, so the harness can watch the boot ------------------
# The DietPi VM image boots to a graphical console only.
log "adding a serial console to grub.cfg"
debugfs -R "dump /boot/grub/grub.cfg $STAGING/grub.cfg" "$PART" 2> /dev/null
sed -i 's|\(^[[:blank:]]*linux[[:blank:]]\+/boot/vmlinuz[^\n]*\)|\1 console=tty0 console=ttyS0,115200|' \
  "$STAGING/grub.cfg"
if ! grep -q 'serial --unit=0' "$STAGING/grub.cfg"
then
  sed -i '1i serial --unit=0 --speed=115200\nterminal_input --append serial\nterminal_output --append serial' \
    "$STAGING/grub.cfg"
fi

# --- write everything back ------------------------------------------------
write_file () {
  local local_path="$1" image_path="$2" mode="${3:-}"
  debugfs -w -R "rm $image_path" "$PART" &> /dev/null || true
  debugfs -w -R "write $local_path ${image_path#/}" "$PART" 2>&1 | grep -v "^debugfs" || true
  [ -n "$mode" ] && debugfs -w -R "sif $image_path mode $mode" "$PART" &> /dev/null || true
}

# debugfs 'write' only takes a target directory implicitly, so go via /boot
cd "$STAGING"
for f in dietpi.txt teslausb_setup_variables.conf Automation_Custom_Script.sh dietpi-wifi.txt
do
  [ -f "$f" ] || continue
  log "installing /boot/$f"
  debugfs -w -R "rm /boot/$f" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/$f /boot/$f" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
done
log "installing patched /boot/grub/grub.cfg"
debugfs -w -R "rm /boot/grub/grub.cfg" "$PART" &> /dev/null || true
debugfs -w -R "write $STAGING/grub.cfg /boot/grub/grub.cfg" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true

# Automation_Custom_Script.sh must be executable, and DietPi chmods it anyway,
# but set it so the log is honest about what is on the image.
debugfs -w -R "sif /boot/Automation_Custom_Script.sh mode 0100755" "$PART" &> /dev/null || true

# teslausb's own scripts, so the VM tests the working tree instead of whatever
# is on GitHub. The bootstrap picks these up if they are present.
log "installing the local teslausb scripts for an offline install"
debugfs -w -R "mkdir /boot/teslausb-local" "$PART" &> /dev/null || true
for f in /repo/setup/pi/first-boot.sh /repo/setup/pi/teslausb-setup.service
do
  debugfs -w -R "rm /boot/teslausb-local/$(basename "$f")" "$PART" &> /dev/null || true
  debugfs -w -R "write $f /boot/teslausb-local/$(basename "$f")" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
done

e2fsck -fp "$PART" > /dev/null 2>&1 || true

log "writing the partition back"
dd if="$PART" of="$WORK" bs=512 seek="$start" conv=notrunc status=none

cp "$WORK" /cache/teslausb-vm.img
# The container runs as root; hand the image back to whoever invoked us so QEMU
# can open it without privileges.
if [ -n "${HOST_UID:-}" ]
then
  chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" /cache/teslausb-vm.img
fi
chmod 664 /cache/teslausb-vm.img
log "image ready: $(du -h /cache/teslausb-vm.img | cut -f1)"
