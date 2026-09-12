#!/bin/bash
#
# usb-link-watchdog.sh — reboot the Pi when the car stops seeing the USB drive.
#
# WHY: the car's USB host can drop the gadget and latch the port off. Once that
# happens the car may never re-enumerate the drive, and teslausb's own
# disconnect/reconnect cycle does not clear it. Only a full reboot, which
# unbinds and reloads dwc2, brings the link back.
#
# DETECTION: the Pi is powered only while the car is awake, and an awake car
# writes dashcam footage continuously. So if the gadget is "configured" but the
# backing file has not been written for STALL_MINS, the car is no longer talking
# to us. Kernel ep1out errors are logged as evidence but are not used as a
# trigger, because a fatal latch-off can occur without producing any.
#
# SAFETY: cooldown between reboots, and never reboots while teslausb is
# mid-archive (cam or archive mounted, or rsync running), so an in-flight
# archive copy is not cut off.
#
set -uo pipefail

readonly CAM_IMAGE="/backingfiles/cam_disk.bin"
readonly STALL_MINS=15          # no writes for this long => car isn't seeing us
readonly MIN_UPTIME_MINS=20     # give the Pi time to boot and settle first
readonly COOLDOWN_MINS=30       # minimum gap between automatic reboots
readonly LOG="/mutable/usb-link-watchdog.log"
readonly STATE="/mutable/usb-link-watchdog.last-reboot"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG"; }

now=$(date +%s)
uptime_s=$(awk '{print int($1)}' /proc/uptime)

# --- give the system time to settle after boot -----------------------------
if (( uptime_s < MIN_UPTIME_MINS * 60 )); then
    exit 0
fi

# --- is the gadget even presented? -----------------------------------------
state=$(cat /sys/class/udc/*/state 2>/dev/null | head -1)
if [[ "$state" != "configured" ]]; then
    # teslausb detaches the gadget during its own archive cycle; that's normal
    # and short-lived, so this is not a fault condition.
    exit 0
fi

# --- never interrupt an archive in progress --------------------------------
#   cifs backend : /mnt/archive stays mounted for the whole archive
#   rsync backend: NOTHING is ever mounted (connect-archive.sh is a no-op),
#                  so the mount check alone is blind. Look for the rsync
#                  process too — teslausb runs rsync without --partial, so a
#                  reboot mid-transfer discards the in-flight file.
if findmnt -rn /mnt/archive >/dev/null 2>&1 \
   || findmnt -rn /mnt/cam >/dev/null 2>&1 \
   || pgrep -x rsync >/dev/null 2>&1; then
    exit 0
fi

# --- how long since the car last wrote anything? ---------------------------
[[ -e "$CAM_IMAGE" ]] || { log "ERROR: $CAM_IMAGE missing"; exit 1; }
mtime=$(stat -c %Y "$CAM_IMAGE")
idle_s=$(( now - mtime ))

if (( idle_s < STALL_MINS * 60 )); then
    exit 0   # healthy: writes are flowing
fi

# --- stalled. respect the cooldown so we cannot loop -----------------------
last=0
[[ -r "$STATE" ]] && last=$(cat "$STATE" 2>/dev/null || echo 0)
[[ "$last" =~ ^[0-9]+$ ]] || last=0
if (( now - last < COOLDOWN_MINS * 60 )); then
    log "STALLED ${idle_s}s but within ${COOLDOWN_MINS}m cooldown (last reboot $(( (now-last)/60 ))m ago); not rebooting"
    exit 0
fi

# --- collect a little evidence before we lose the running kernel log -------
ep1=$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -c "ep1out" || true)
log "ACTION: no writes to cam disk for ${idle_s}s while gadget=configured (uptime $((uptime_s/60))m, ep1out errors this boot: ${ep1}) -> rebooting to reset dwc2"
printf '%s' "$now" > "$STATE"
sync
/sbin/reboot
