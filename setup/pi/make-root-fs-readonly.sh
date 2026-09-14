#!/bin/bash

# Adapted from https://github.com/adafruit/Raspberry-Pi-Installer-Scripts/blob/master/read-only-fs.sh

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "make-root-fs-readonly: $1"
    return
  fi
  echo "make-root-fs-readonly: $1"
}

if [ "${SKIP_READONLY:-false}" = "true" ]
then
  log_progress "Skipping"
  exit 0
fi

log_progress "start"

function append_cmdline_txt_param() {
  local toAppend="$1"
  # Don't add the option if it is already added.
  # If the command line gets too long the pi won't boot.
  # Look for the option at the end ($) or in the middle
  # of the command line and surrounded by space (\s).
  if [ -f "$CMDLINE_PATH" ] && ! grep -P -q "\s${toAppend}(\$|\s)" "$CMDLINE_PATH"
  then
    sed -i "s/\'/ ${toAppend}/g" "$CMDLINE_PATH" >/dev/null
  fi
}

function remove_cmdline_txt_param() {
  if [ -f "$CMDLINE_PATH" ]
  then
    sed -i "s/\(\s\)${1}\(\s\|$\)//" "$CMDLINE_PATH" > /dev/null
  fi
}

log_progress "Disabling unnecessary service..."
systemctl disable apt-daily.timer
systemctl disable apt-daily-upgrade.timer

# DietPi-RAMlog and teslausb both want to own /var/log as a tmpfs, and DietPi's
# version cannot survive a read-only root: dietpi-ramlog.service does
# 'mkdir -p /var/lib/dietpi/logs' on start and writes the preserved log metadata
# back there on stop, both of which are writes to the root filesystem. Its fstab
# entry would also win over the one added below, because that is only added when
# no /var/log entry exists.
#
# So remove it through dietpi-software, which keeps DietPi's own install state
# consistent, and clean up the mount and fstab entry if anything is left. This
# lives here rather than only in the DietPi bootstrap script so that installs
# started by hand are covered too.
# dietpi-software is happy to sit and wait. In an environment without systemd it
# stalls indefinitely on "uninstall", and an interrupted test run left hour-old
# orphans of it behind. Setup runs unattended from a systemd unit, so every call
# gets a closed stdin and a deadline, and the end state is made sure of with apt
# afterwards regardless of what dietpi-software managed.
function dietpi_software () {
  timeout "${DIETPI_SOFTWARE_TIMEOUT:-600}" /boot/dietpi/dietpi-software "$@" < /dev/null
}

# Anything that lived in /var/log while DietPi's RAMlog was mounted has just gone
# with it, including the mount point configure-web.sh made for nginx's log tmpfs.
# Recreate it on the real /var/log, while the root filesystem is still writable,
# otherwise that mount fails on the next boot and takes local-fs.target with it.
# DietPi ships dietpi-ramlog_disable.service, which writes its log into
# /var/lib/dietpi/logs. Once RAMlog itself has been removed the unit has nothing to
# do, and once the root filesystem is read-only its redirection fails and dash exits
# 2, so every boot ends with a failed unit for no reason.
function disable_dietpi_ramlog_units () {
  local unit
  for unit in dietpi-ramlog_disable.service dietpi-ramlog.service
  do
    systemctl is-enabled "$unit" &> /dev/null || continue
    log_progress "disabling $unit, which has nothing left to do"
    systemctl disable "$unit" &> /dev/null || log_progress "WARNING: could not disable $unit"
  done
}

function restore_nginx_log_mountpoint () {
  grep -q "/var/log/nginx" /etc/fstab || return 0
  [ -d /var/log/nginx ] && return 0
  log_progress "recreating /var/log/nginx, which went with DietPi-RAMlog"
  mkdir -p /var/log/nginx
  chown root:adm /var/log/nginx
  chmod 755 /var/log/nginx
}

function remove_dietpi_ramlog () {
  if ! grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab 2> /dev/null &&
     ! findmnt -t tmpfs /var/log > /dev/null 2>&1
  then
    log_progress "DietPi-RAMlog is not in use"
    return 0
  fi

  log_progress "Removing DietPi-RAMlog so teslausb can own /var/log"
  if [ -x /boot/dietpi/dietpi-software ]
  then
    dietpi_software uninstall 103 || \
      log_progress "WARNING: dietpi-software uninstall 103 failed"
  fi

  systemctl disable dietpi-ramlog &> /dev/null || true
  systemctl stop dietpi-ramlog &> /dev/null || true

  if grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab 2> /dev/null
  then
    log_progress "dropping DietPi's /var/log entry from /etc/fstab"
    sed -i '/[[:blank:]]\/var\/log[[:blank:]]/d' /etc/fstab
  fi
  if findmnt -t tmpfs /var/log > /dev/null 2>&1
  then
    umount -Rfl /var/log || log_progress "WARNING: could not unmount the /var/log tmpfs"
  fi
  mkdir -p /var/log
}

remove_dietpi_ramlog
restore_nginx_log_mountpoint
disable_dietpi_ramlog_units

# adb service exists on some distributions and interferes with mass storage emulation
systemctl disable amlogic-adbd &> /dev/null || true
systemctl disable radxa-adbd radxa-usbnet &> /dev/null || true

# don't restore the led state from the time the root fs was made read-only
systemctl disable armbian-led-state &> /dev/null || true

log_progress "Removing unwanted packages..."
# Logrotate and Rsyslog are DietPi software items (101 and 102); remove them the
# DietPi way so its install state does not drift, then let apt clean up whatever
# was not installed through DietPi.
if [ -x /boot/dietpi/dietpi-software ]
then
  dietpi_software uninstall 101 102 &> /dev/null || \
    log_progress "WARNING: could not uninstall Logrotate/Rsyslog via dietpi-software"
fi
apt-get remove -y --purge triggerhappy logrotate dphys-swapfile
apt-get -y autoremove --purge
# Replace log management with busybox (use logread if needed)
log_progress "Installing ntp and busybox-syslogd..."
apt-get -y install ntp busybox-syslogd; dpkg --purge rsyslog

log_progress "Configuring system..."

# Add fsck.mode=auto, noswap and/or ro to end of cmdline.txt
# Remove the fastboot parameter because it makes fsck not run
remove_cmdline_txt_param fastboot
append_cmdline_txt_param fsck.mode=auto
append_cmdline_txt_param noswap
append_cmdline_txt_param ro

# set root and mutable max mount count to 1, so they're checked every boot
tune2fs -c 1 "$ROOT_PARTITION_DEVICE" || log_progress "tune2fs failed for rootfs"
tune2fs -c 1 /dev/disk/by-label/mutable || log_progress "tune2fs failed for mutable"

# we're not using swap, so delete the swap file for some extra space
# The swap file has to go, but so does the fstab entry that activates it. DietPi
# keeps swap as /var/swap with an fstab line, unlike Raspberry Pi OS where removing
# dphys-swapfile was enough. Deleting only the file leaves systemd trying to swapon
# a file that is not there, which fails local-fs.target and drops the device into
# emergency mode on the next boot.
if [ -x /boot/dietpi/func/dietpi-set_swapfile ]
then
  # DietPi's own way, which also keeps its records straight
  /boot/dietpi/func/dietpi-set_swapfile 0 < /dev/null &> /dev/null || \
    log_progress "WARNING: dietpi-set_swapfile could not disable swap"
fi
swapoff /var/swap &> /dev/null || true
sed -i '\|^/var/swap[[:blank:]]|d' /etc/fstab
rm -f /var/swap

# Move fake-hwclock.data to /mutable directory so it can be updated
if ! findmnt --mountpoint /mutable > /dev/null
then
  log_progress "Mounting the mutable partition..."
  mount /mutable
  log_progress "Mounted."
fi
if [ ! -e "/mutable/etc" ]
then
  mkdir -p /mutable/etc
fi

if [ ! -L "/etc/fake-hwclock.data" ] && [ -e "/etc/fake-hwclock.data" ]
then
  log_progress "Moving fake-hwclock data"
  mv /etc/fake-hwclock.data /mutable/etc/fake-hwclock.data
  ln -s /mutable/etc/fake-hwclock.data /etc/fake-hwclock.data
fi
# By default fake-hwclock is run during early boot, before /mutable
# has been mounted and so will fail. Delay running it until /mutable
# has been mounted.
if [ -e /lib/systemd/system/fake-hwclock.service ]
then
  sed -i 's/Before=.*/After=mutable.mount/' /lib/systemd/system/fake-hwclock.service
fi

if [ -d /var/lib/NetworkManager/ ] && [ -n "$AP_SSID" ]
then
  log_progress "Moving /var/lib/NetworkManager to mutable"
  mkdir -p /mutable/var/lib/
  mv /var/lib/NetworkManager /mutable/var/lib/
  ln -s /mutable/var/lib/NetworkManager/ /var/lib/NetworkManager
fi

# Create a configs directory for others to use
if [ ! -e "/mutable/configs" ]
then
  mkdir -p /mutable/configs
fi

# Move /var/spool to /tmp
if [ -L /var/spool ]
then
  log_progress "fixing /var/spool"
  rm /var/spool
  mkdir /var/spool
  chmod 755 /var/spool
  # a tmpfs fstab entry for /var/spool will be added below
else
  rm -rf /var/spool/*
fi

# Change spool permissions in var.conf (rondie/Margaret fix)
sed -i "s/spool\s*0755/spool 1777/g" /usr/lib/tmpfiles.d/var.conf >/dev/null

# Move resolv.conf to /mutable if it is not located on a tmpfs.
# This used to move it to /tmp, but some resolvers apparently don't rewrite
# /etc/resolv.conf when it's missing, so store it on /mutable to provide
# persistence while still being mutable.
read -r resolvconflocation <<< "$(df --output=fstype "$(readlink -f /etc/resolv.conf)" | tail -1)"
if [ "$resolvconflocation" != "tmpfs" ] && [ ! -e /mutable/resolv.conf ]
then
  mv "$(readlink -f /etc/resolv.conf)" /mutable/resolv.conf
  ln -sf /mutable/resolv.conf /etc/resolv.conf
fi

# Update /etc/fstab
# make /boot read-only
# make / read-only
# tmpfs /var/log tmpfs nodev,nosuid 0 0
# tmpfs /var/tmp tmpfs nodev,nosuid 0 0
# tmpfs /tmp     tmpfs nodev,nosuid 0 0
if ! grep -P -q "/boot\s+vfat\s+.+?(?=,ro)" /etc/fstab
then
  sed -i -r "s@(/boot\s+vfat\s+\S+)@\1,ro@" /etc/fstab
fi

if ! grep -P -q "/boot/firmware\s+vfat\s+.+?(?=,ro)" /etc/fstab
then
  sed -i -r "s@(/boot/firmware\s+vfat\s+\S+)@\1,ro@" /etc/fstab
fi

if ! grep -P -q "/\s+ext4\s+.+?(?=,ro)" /etc/fstab
then
  sed -i -r "s@(/\s+ext4\s+\S+)@\1,ro@" /etc/fstab
fi

if ! grep -w -q "/var/log" /etc/fstab
then
  echo "tmpfs /var/log tmpfs nodev,nosuid 0 0" >> /etc/fstab
fi

if ! grep -w -q "/var/tmp" /etc/fstab
then
  echo "tmpfs /var/tmp tmpfs nodev,nosuid 0 0" >> /etc/fstab
fi

if ! grep -w -q "/tmp" /etc/fstab
then
  echo "tmpfs /tmp    tmpfs nodev,nosuid 0 0" >> /etc/fstab
fi

if ! grep -w -q "/var/spool" /etc/fstab
then
  echo "tmpfs /var/spool tmpfs nodev,nosuid 0 0" >> /etc/fstab
fi

if ! grep -w -q "/var/lib/ntp" /etc/fstab
then
  if [ ! -d /var/lib/ntp ]
  then
    rm -rf /var/lib/ntp
    mkdir -p /var/lib/ntp
  fi
  echo "tmpfs /var/lib/ntp tmpfs nodev,nosuid 0 0" >> /etc/fstab
fi

# work around 'mount' warning that's printed when /etc/fstab is
# newer than /run/systemd/systemd-units-load
touch -t 197001010000 /etc/fstab

# autofs by default has dependencies on various network services, because
# one of its purposes is to automount NFS filesystems.
# TeslaUSB doesn't use NFS though, and removing those dependencies speeds
# up TeslaUSB startup.
if [ ! -e /etc/systemd/system/autofs.service ]
then
  grep -v '^Wants=\|^After=' /lib/systemd/system/autofs.service  > /etc/systemd/system/autofs.service
fi

log_progress "done"
