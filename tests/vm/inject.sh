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
: "${GROW_GB:=8}"

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

# --- give the root filesystem a workable size, and leave the rest free -----
#
# Two constraints pull against each other. DietPi expands the root partition over
# the whole disk on first boot, which leaves teslausb no room for the
# backingfiles partition; but the image's native 1G root is too small for
# DietPi's own first run, which does a full apt upgrade and ran out of space at
# 87MB free. So size the root deliberately here, before first boot, and leave the
# remainder for teslausb.
if [ "${ROOT_SIZE_GB:-3}" != 0 ]
then
  log "growing the root partition to ${ROOT_SIZE_GB:-3}G, leaving the rest for teslausb"
  start=$(sfdisk -d "$WORK" | sed -n 's/.*start=[[:blank:]]*\([0-9][0-9]*\).*type=83.*/\1/p' | head -1)
  sectors=$(( ${ROOT_SIZE_GB:-3} * 1024 * 1024 * 2 ))
  printf '%s,%s\n' "$start" "$sectors" | sfdisk --force -N1 "$WORK" > /dev/null 2>&1 || \
    log "WARNING: could not resize the root partition"
  # grow the filesystem to match, offline
  dd if="$WORK" of=/tmp/rootgrow.img bs=512 skip="$start" count="$sectors" status=none
  e2fsck -fp /tmp/rootgrow.img > /dev/null 2>&1 || true
  resize2fs /tmp/rootgrow.img > /dev/null 2>&1 || log "WARNING: resize2fs failed"
  dd if=/tmp/rootgrow.img of="$WORK" bs=512 seek="$start" conv=notrunc status=none
  rm -f /tmp/rootgrow.img
fi

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
#
# TESLAUSB_BOOTSTRAP=0 prepares a plain DietPi instead, which is what the lab's
# NAS needs: it is a machine on the network to archive to, not a second teslausb.
if [ "${TESLAUSB_BOOTSTRAP:-1}" = 1 ]
then
  log "running tools/prepare-boot-partition.sh"
  /repo/tools/prepare-boot-partition.sh "$STAGING" "$CONF" | sed 's/^/    /'
else
  log "plain DietPi (no teslausb bootstrap)"
  for kv in AUTO_SETUP_AUTOMATED=1 "AUTO_SETUP_GLOBAL_PASSWORD=${VM_PASSWORD:-teslausb-lab}"
  do
    key=${kv%%=*}
    if grep -q "^${key}=" "$STAGING/dietpi.txt"
    then sed -i "s|^${key}=.*|${kv}|" "$STAGING/dietpi.txt"
    else printf '%s\n' "$kv" >> "$STAGING/dietpi.txt"
    fi
  done
fi

# --- extra dietpi.txt keys for the test environment -----------------------
# Applied after the production script has run, so the test can pin things the
# real script has no business setting, such as a static address.
if [ -n "${DIETPI_EXTRA_KEYS:-}" ]
then
  while IFS= read -r kv
  do
    [ -n "$kv" ] || continue
    key=${kv%%=*}
    log "dietpi.txt: $kv"
    if grep -q "^${key}=" "$STAGING/dietpi.txt"
    then
      sed -i "s|^${key}=.*|${kv}|" "$STAGING/dietpi.txt"
    else
      printf '%s\n' "$kv" >> "$STAGING/dietpi.txt"
    fi
  done <<< "$DIETPI_EXTRA_KEYS"
fi

# --- a serial console, so the harness can watch the boot ------------------
# The DietPi VM image boots to a graphical console only.
log "adding a serial console to grub.cfg"
debugfs -R "dump /boot/grub/grub.cfg $STAGING/grub.cfg" "$PART" 2> /dev/null
sed -i 's|\(^[[:blank:]]*linux[[:blank:]]\+/boot/vmlinuz[^\n]*\)|\1 console=ttyS0,115200|' \
  "$STAGING/grub.cfg"
if ! grep -q 'serial --unit=0' "$STAGING/grub.cfg"
then
  sed -i '1i serial --unit=0 --speed=115200\nterminal_input --append serial\nterminal_output --append serial' \
    "$STAGING/grub.cfg"
fi

# Make the serial console survive DietPi regenerating grub.cfg.
#
# DietPi's first run setup upgrades the kernel, which runs update-grub and
# rewrites grub.cfg from /etc/default/grub, discarding the patch above. The boot
# then goes back to the graphical console and the harness goes blind exactly when
# the interesting part starts, so set it in the file update-grub reads from too.
log "persisting the serial console in /etc/default/grub"
debugfs -R "dump /etc/default/grub $STAGING/grub.default" "$PART" 2> /dev/null || : > "$STAGING/grub.default"
grep -vE '^[[:blank:]]*(GRUB_CMDLINE_LINUX|GRUB_TERMINAL|GRUB_SERIAL_COMMAND|GRUB_TIMEOUT)=' \
  "$STAGING/grub.default" > "$STAGING/grub.default.new" || true
cat >> "$STAGING/grub.default.new" <<'EOF'
# added by the teslausb VM test: keep a serial console across kernel upgrades
GRUB_CMDLINE_LINUX="console=ttyS0,115200"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
GRUB_TIMEOUT=2
EOF
debugfs -w -R "rm /etc/default/grub" "$PART" &> /dev/null || true
debugfs -w -R "write $STAGING/grub.default.new /etc/default/grub" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true

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

# The working tree, so the VM tests these sources rather than whatever is
# published on GitHub. Earlier runs downloaded the upstream tarball and quietly
# exercised pre-port code, rc.local and all. first-boot.sh unpacks this and
# points SOURCE_DIR at it, which makes teslausb's copy_script skip downloading.
if [ "${TESLAUSB_BOOTSTRAP:-1}" = 1 ]
then
log "staging the working tree for an offline install"
debugfs -w -R "mkdir /boot/teslausb-local" "$PART" &> /dev/null || true
tar -cf /tmp/repo.tar -C /repo \
  --exclude=.git --exclude=node_modules --exclude='._*' \
  setup run dietpi tools tests check.sh 2> /dev/null
for f in /repo/setup/pi/first-boot.sh /repo/setup/pi/teslausb-setup.service /tmp/repo.tar
do
  debugfs -w -R "rm /boot/teslausb-local/$(basename "$f")" "$PART" &> /dev/null || true
  debugfs -w -R "write $f /boot/teslausb-local/$(basename "$f")" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
done
log "staged $(du -h /tmp/repo.tar | cut -f1) of sources"
fi

# DNS override.
#
# Needed for macvtap: a macvtap guest cannot talk to its own host, so if the LAN
# hands out that host as the DNS server (a Pi-hole or similar), the VM has no
# working resolver and DietPi's first run setup gives up. Superseding the option
# in dhclient.conf keeps DHCP for everything else.
if [ -n "${VM_DNS:-}" ]
then
  log "pointing DNS at $VM_DNS"
  debugfs -R "dump /etc/dhcp/dhclient.conf $STAGING/dhclient.conf" "$PART" 2> /dev/null
  {
    echo
    echo "# added by the teslausb VM test: see tests/vm/inject.sh"
    echo "supersede domain-name-servers ${VM_DNS};"
  } >> "$STAGING/dhclient.conf"
  debugfs -w -R "rm /etc/dhcp/dhclient.conf" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/dhclient.conf /etc/dhcp/dhclient.conf" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
  # and a resolv.conf for the window before dhclient runs
  printf 'nameserver %s\n' "${VM_DNS%%,*}" > "$STAGING/resolv.conf"
  debugfs -w -R "rm /etc/resolv.conf" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/resolv.conf /etc/resolv.conf" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
fi

# Make the first boot wait for the network.
#
# dietpi.txt ships AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=1, but the service that
# implements it (ifupdown-wait-online) is only enabled once DietPi's first run
# setup has completed, so the very first boot can race its own DHCP lease. When
# it loses, DietPi-Update reports "Network is unreachable", terminates, and waits
# for someone to confirm a retry on the console, which is fatal for an unattended
# install. Enabling it up front makes the boot deterministic.
log "enabling ifupdown-wait-online for the first boot"
debugfs -w -R "mkdir /etc/systemd/system/network-online.target.wants" "$PART" &> /dev/null || true
debugfs -w -R "symlink /etc/systemd/system/network-online.target.wants/ifupdown-wait-online.service /lib/systemd/system/ifupdown-wait-online.service" "$PART" &> /dev/null || true

# Hold DietPi's first run setup until the network genuinely works.
#
# DietPi-Update's first action is 'ping -4nc 1 -W 10 9.9.9.9', and it terminates
# if that fails. ifupdown-wait-online finishes in under two seconds while
# dhclient does not start until around four, so on a fast boot DietPi loses the
# race, gives up, and then waits for someone to confirm a retry on the console.
# Gate the autologin console, which is where first run setup runs, on real
# connectivity rather than on systemd's idea of it.
log "making the first run setup wait for working connectivity"
cat > "$STAGING/wait-network.conf" <<'EOF'
[Service]
ExecStartPre=/bin/sh -c 'i=0; until ping -4nc1 -W2 9.9.9.9 >/dev/null 2>&1 || [ $i -ge 60 ]; do i=$((i+1)); sleep 2; done'
TimeoutStartSec=300
EOF
for d in /etc/systemd/system/getty@tty1.service.d /etc/systemd/system/serial-getty@ttyS0.service.d
do
  debugfs -w -R "mkdir $d" "$PART" &> /dev/null || true
  debugfs -w -R "rm $d/zz-wait-network.conf" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/wait-network.conf $d/zz-wait-network.conf" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
done

# DietPi runs its first run setup on an autologin console, which is tty1 by
# default and therefore invisible to the harness. Give it an autologin serial
# console instead, so everything it does, including any prompt it would wait on,
# lands in the serial log.
log "putting the DietPi console on serial"
cat > "$STAGING/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200,38400,9600 vt100
EOF
debugfs -w -R "mkdir /etc/systemd/system/serial-getty@ttyS0.service.d" "$PART" &> /dev/null || true
debugfs -w -R "rm /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" "$PART" &> /dev/null || true
debugfs -w -R "write $STAGING/autologin.conf /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
debugfs -w -R "mkdir /etc/systemd/system/getty.target.wants" "$PART" &> /dev/null || true
debugfs -w -R "symlink /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service /lib/systemd/system/serial-getty@.service" "$PART" &> /dev/null || true

# Force DietPi's first run setup onto the serial console.
#
# /etc/bashrc.d/dietpi.bash calls dietpi-login from any interactive login shell,
# and the image autologs into tty1, which the harness cannot see. Masking tty1
# leaves the autologin serial console as the only one, so everything first run
# setup does, including any prompt it would block on, appears in the serial log.
# tty1 is deliberately left alone. DietPi advances its first run setup from
# /etc/bashrc.d/dietpi.bash, which calls dietpi-login for any interactive login
# shell, and the image autologs into tty1 to make that happen. Masking tty1
# stops first run setup dead.

# Stop DietPi expanding the root partition over the free space.
#
# DietPi grows the root partition to fill the disk on first boot, which leaves
# teslausb nothing to carve the backingfiles partition out of: setup gets as far
# as printing a partition table with a single partition and can go no further.
# The marker below is DietPi's own mechanism for "the partition table is already
# how I want it", so the filesystem expansion becomes a no-op and the free space
# survives.
if [ "${SKIP_DIETPI_RESIZE:-1}" = 1 ]
then
  log "keeping DietPi from expanding the root partition over the free space"
  : > "$STAGING/skip_partition_resize"
  debugfs -w -R "rm /dietpi_skip_partition_resize" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/skip_partition_resize /dietpi_skip_partition_resize" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
fi

# Ask DietPi for OpenSSH.
#
# The values are counter-intuitive: 0 is none/custom, -1 Dropbear, -2 OpenSSH.
# Images ship with 0, so DietPi's software phase REMOVES the pre-installed
# Dropbear and the VM becomes unreachable half way through a run, which is
# exactly what happened before this was set.
log "asking DietPi for OpenSSH (index -2)"
if grep -q '^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=' "$STAGING/dietpi.txt"
then
  sed -i 's|^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=.*|AUTO_SETUP_SSH_SERVER_INDEX=-2|' "$STAGING/dietpi.txt"
else
  echo 'AUTO_SETUP_SSH_SERVER_INDEX=-2' >> "$STAGING/dietpi.txt"
fi

# Skip DietPi's own update phase.
#
# dietpi-login runs three phases: update (install stage 0), then software
# (stage 1, which runs Automation_Custom_Script.sh), then finished (stage 2).
# The update phase begins with 'ping -4nc 1 -W 10 9.9.9.9' and terminates the
# whole first run if that fails, which it does on a fast VM boot before the DHCP
# lease exists. That is DietPi's updater, not teslausb, and it is not what this
# test is for: start at stage 1 so the boot goes straight to the phase that runs
# the teslausb bootstrap.
if [ "${SKIP_DIETPI_UPDATE:-1}" = 1 ]
then
  log "starting at install stage 1, skipping DietPi's update phase"
  printf '1' > "$STAGING/install_stage"
  debugfs -w -R "rm /boot/dietpi/.install_stage" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/install_stage /boot/dietpi/.install_stage" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
fi

# A ping that works without host ICMP privileges.
#
# DietPi's first run setup begins with 'ping -4nc 1 -W 10 9.9.9.9' and refuses to
# continue if it fails. QEMU's user-mode networking can only carry ICMP when the
# host allows unprivileged ping sockets, which many hosts do not, so first run
# setup dies on a VM that in fact has perfectly good TCP and DNS. Rather than
# asking for a sysctl change on the host, give the guest a ping that falls back
# to a TCP connect when ICMP is unavailable.
if [ "${PING_SHIM:-1}" = 1 ]
then
  log "installing a ping that falls back to TCP"
  cat > "$STAGING/ping" <<'EOF'
#!/bin/bash
# teslausb VM test shim: see tests/vm/inject.sh
if /bin/ping "$@" 2> /dev/null
then
  exit 0
fi
# ICMP is unavailable (QEMU user-mode networking without host ping sockets).
# Fall back to proving the network works with a TCP connect.
for target in 1.1.1.1:443 9.9.9.9:443 deb.debian.org:443
do
  if timeout 5 bash -c "echo > /dev/tcp/${target%:*}/${target##*:}" 2> /dev/null
  then
    exit 0
  fi
done
exit 1
EOF
  debugfs -w -R "mkdir /usr/local/bin" "$PART" &> /dev/null || true
  debugfs -w -R "rm /usr/local/bin/ping" "$PART" &> /dev/null || true
  debugfs -w -R "write $STAGING/ping /usr/local/bin/ping" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
  debugfs -w -R "sif /usr/local/bin/ping mode 0100755" "$PART" &> /dev/null || true
fi

# An extra interface, used by the two VM lab for its private segment. DietPi's
# dietpi.txt only configures one interface, so this goes in as an interfaces.d
# snippet, which ifupdown picks up on its own.
if [ -n "${EXTRA_INTERFACES:-}" ] && [ -f "$EXTRA_INTERFACES" ]
then
  log "adding a second interface from $(basename "$EXTRA_INTERFACES")"
  debugfs -w -R "mkdir /etc/network/interfaces.d" "$PART" &> /dev/null || true
  debugfs -w -R "rm /etc/network/interfaces.d/lab" "$PART" &> /dev/null || true
  debugfs -w -R "write $EXTRA_INTERFACES /etc/network/interfaces.d/lab" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
fi

# An SSH key for root, so the checks can log in without a password. Dropbear,
# which is what DietPi installs by default, reads /root/.ssh/authorized_keys and
# insists on tight permissions.
if [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]
then
  log "installing an SSH key for root"
  debugfs -w -R "mkdir /root/.ssh" "$PART" &> /dev/null || true
  debugfs -w -R "rm /root/.ssh/authorized_keys" "$PART" &> /dev/null || true
  debugfs -w -R "write $SSH_PUBKEY /root/.ssh/authorized_keys" "$PART" 2>&1 | grep -iv "^debugfs\|^$" || true
  debugfs -w -R "sif /root/.ssh mode 040700" "$PART" &> /dev/null || true
  debugfs -w -R "sif /root/.ssh uid 0" "$PART" &> /dev/null || true
  debugfs -w -R "sif /root/.ssh gid 0" "$PART" &> /dev/null || true
  debugfs -w -R "sif /root/.ssh/authorized_keys mode 0100600" "$PART" &> /dev/null || true
  debugfs -w -R "sif /root/.ssh/authorized_keys uid 0" "$PART" &> /dev/null || true
  debugfs -w -R "sif /root/.ssh/authorized_keys gid 0" "$PART" &> /dev/null || true
fi

e2fsck -fp "$PART" > /dev/null 2>&1 || true

log "writing the partition back"
dd if="$PART" of="$WORK" bs=512 seek="$start" conv=notrunc status=none

readonly OUT="${OUT_IMAGE:-/cache/teslausb-vm.img}"
cp "$WORK" "$OUT"
# The container runs as root; hand the image back to whoever invoked us so QEMU
# can open it without privileges.
if [ -n "${HOST_UID:-}" ]
then
  chown "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT"
fi
chmod 664 "$OUT"
log "image ready: $(du -h "$OUT" | cut -f1)"
