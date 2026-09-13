#!/bin/bash
#
# usb-link-watchdog.sh — reboot the Pi when the car stops seeing the USB drive.
#
# WHY: the car's USB host can drop the gadget and latch the port off. Once that
# happens the car may never re-enumerate the drive: a link reset can recover, or
# it can leave the port dead for hours. teslausb's own disconnect/reconnect cycle
# does not clear it; only a full reboot, which unbinds and reloads dwc2, does.
#
# DETECTION: the Pi is powered only while the car is awake, and an awake car
# writes dashcam footage continuously. So if the gadget is "configured" but the
# backing file has not been written for STALL_MINS, the car is no longer talking
# to us. Kernel ep1out errors are logged as evidence but are not used as a
# trigger, because a fatal latch-off can happen without producing any.
#
# WHY THIS DOES NOT SIMPLY SKIP WHILE RSYNC RUNS:
#
# An earlier version exited as soon as rsync was alive, to avoid discarding an
# in-flight file. In practice the NAS upload runs for hours, roughly one clip
# every 40 to 60 seconds over CIFS, so 'pgrep -x rsync' matched essentially
# always and the watchdog became a permanent no-op: the slow upload and a dead
# USB link masked each other, and a car left with dashcam_state=Unavailable for
# hours never triggered a reboot.
#
# So a stall can now fire during an archive, with two guards keeping it safe:
#
#   1. The car must not be demonstrably recording. If Tessie reports
#      dashcam_state=Recording recently enough to trust, a quiet backing file is
#      a false alarm and nothing happens.
#   2. If rsync is mid-file we wait for it to finish the current one, which it
#      reports as a line in its log. Falling past that wait costs at most one
#      re-sent clip, because --remove-source-files only unlinks after a
#      successful transfer.
#
# SAFETY: a cooldown between reboots, and DRY_RUN=1 to exercise every decision
# without rebooting or writing the cooldown marker:
#
#   DRY_RUN=1 /root/bin/usb-link-watchdog.sh
#
set -uo pipefail

# All of these are overridable from the environment so the script can be
# exercised against a fixture directory; the defaults are the real paths.
readonly CAM_IMAGE="${CAM_IMAGE:-/backingfiles/cam_disk.bin}"
readonly UDC_DIR="${UDC_DIR:-/sys/class/udc}"
readonly UPTIME_FILE="${UPTIME_FILE:-/proc/uptime}"
readonly STALL_MINS="${STALL_MINS:-15}"                   # no writes this long => car isn't seeing us
readonly MIN_UPTIME_MINS="${MIN_UPTIME_MINS:-20}"         # give the Pi time to boot and settle first
readonly COOLDOWN_MINS="${COOLDOWN_MINS:-30}"             # minimum gap between automatic reboots
readonly BOUNDARY_WAIT_SECS="${BOUNDARY_WAIT_SECS:-180}"  # how long to wait for rsync to finish a file
readonly MAX_STATE_AGE_SECS="${MAX_STATE_AGE_SECS:-600}"  # ignore a Tessie all-clear older than this
readonly RSYNC_LOG="${RSYNC_LOG:-/tmp/archive-rsync-cmd.log}"  # --log-file from archive-clips.sh
readonly LOG="${LOG:-/mutable/usb-link-watchdog.log}"
readonly STATE="${STATE:-/mutable/usb-link-watchdog.last-reboot}"
readonly REBOOT_CMD="${REBOOT_CMD:-/sbin/reboot}"
readonly SETUP_CONF="${SETUP_CONF:-/root/teslausb_setup_variables.conf}"
readonly DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG"; }

# Ask Tessie whether the car can see the drive. Echoes "<state> <age_seconds>",
# or "unknown -1" if we cannot get an answer. Age matters: Tessie's cached
# vehicle_state can lag by minutes, and a stale "Recording" must not be allowed
# to veto a reboot when the link is genuinely dead.
dashcam_state() {
    local token="${TESSIE_API_TOKEN:-}" vin="${TESSIE_VIN:-}" resp
    if [[ -z "$token" || -z "$vin" ]]; then
        # shellcheck source=/dev/null
        [[ -r "$SETUP_CONF" ]] && source "$SETUP_CONF"
        token="${TESSIE_API_TOKEN:-}"; vin="${TESSIE_VIN:-}"
    fi
    [[ -n "$token" && -n "$vin" ]] || { echo "unknown -1"; return; }
    resp=$(curl -s -m 30 \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        -H "User-Agent: github.com/marcone/teslausb" \
        "https://api.tessie.com/${vin}/state" 2>/dev/null) || { echo "unknown -1"; return; }
    jq -e . >/dev/null 2>&1 <<<"$resp" || { echo "unknown -1"; return; }
    local parsed program
    # $now is a jq variable supplied by --argjson, not a shell one
    # shellcheck disable=SC2016
    program='[(.vehicle_state.dashcam_state // "unknown"), (if .vehicle_state.timestamp then ($now - (.vehicle_state.timestamp / 1000 | floor)) else -1 end)] | "\(.[0]) \(.[1])"'
    parsed=$(jq -r --argjson now "$(date +%s)" "$program" <<<"$resp" 2>/dev/null)
    # Never return nothing: an empty state would match no case arm below and fall
    # straight through to a reboot, so a jq hiccup must read as "no answer".
    [ -n "$parsed" ] || parsed="unknown -1"
    echo "$parsed"
}

# Block until rsync reports a completed file, so a reboot cannot discard one
# mid-flight. rsync's log gets one line per finished file. Returns 0 if a
# boundary was seen (or rsync exited), 1 if we timed out waiting.
wait_for_file_boundary() {
    local deadline=$(( $(date +%s) + BOUNDARY_WAIT_SECS )) before after
    before=$(wc -l < "$RSYNC_LOG" 2>/dev/null || echo 0)
    while (( $(date +%s) < deadline )); do
        pgrep -x rsync >/dev/null 2>&1 || return 0   # transfer ended on its own
        sleep 5
        after=$(wc -l < "$RSYNC_LOG" 2>/dev/null || echo 0)
        (( after > before )) && return 0
    done
    return 1
}

now=$(date +%s)
uptime_s=$(awk '{print int($1)}' "$UPTIME_FILE")

# --- give the system time to settle after boot -----------------------------
if (( uptime_s < MIN_UPTIME_MINS * 60 )); then
    exit 0
fi

# --- is the gadget even presented? -----------------------------------------
state=$(cat "$UDC_DIR"/*/state 2>/dev/null | head -1)
if [[ "$state" != "configured" ]]; then
    # teslausb detaches the gadget during its own archive cycle; that's normal
    # and short-lived, so this is not a fault condition.
    exit 0
fi

# --- is teslausb itself holding the cam disk? -------------------------------
# While /mnt/cam is mounted the Pi owns the image and the car is not expected to
# be writing, so write-idleness means nothing. (The gadget is normally detached
# then too, which the check above already caught, but be explicit.)
if findmnt -rn /mnt/cam >/dev/null 2>&1; then
    exit 0
fi

# --- how long since the car last wrote anything? ---------------------------
# rsync reads from the snapshot mount, never from cam_disk.bin, so this mtime
# reflects the car's writes only and stays meaningful during an archive.
[[ -e "$CAM_IMAGE" ]] || { log "ERROR: $CAM_IMAGE missing"; exit 1; }
mtime=$(stat -c %Y "$CAM_IMAGE")
idle_s=$(( now - mtime ))

if (( idle_s < STALL_MINS * 60 )); then
    exit 0   # healthy: writes are flowing
fi

# --- confirm the car really has lost the drive -----------------------------
archiving=0
if pgrep -x rsync >/dev/null 2>&1 || findmnt -rn /mnt/archive >/dev/null 2>&1; then
    archiving=1
fi

read -r dcstate dcage < <(dashcam_state)
case "$dcstate" in
    Recording)
        if (( dcage >= 0 && dcage <= MAX_STATE_AGE_SECS )); then
            # Car is demonstrably recording; the quiet backing file is not a
            # link fault, so this is a false alarm.
            exit 0
        fi
        log "STALLED ${idle_s}s; dashcam=Recording but reading is ${dcage}s old, too stale to trust as an all-clear"
        ;&
    unknown|"")
        # No trustworthy answer from Tessie, so fall back to the conservative
        # rule of only rebooting when nothing is in flight: an unverified guess
        # must not cost us a transfer. Any other state, such as Unavailable, is a
        # definite answer that the car has lost the drive, and falls through.
        if (( archiving )); then
            log "STALLED ${idle_s}s but dashcam unverified (${dcstate}, age ${dcage}s) and archive in progress; not rebooting"
            exit 0
        fi
        ;;
esac

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

# --- if a transfer is running, stop at a file boundary ---------------------
if (( archiving )) && pgrep -x rsync >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: rsync active; would wait up to ${BOUNDARY_WAIT_SECS}s for a file boundary"
    else
        log "STALLED ${idle_s}s (dashcam=${dcstate}) with rsync active; waiting up to ${BOUNDARY_WAIT_SECS}s for a file boundary"
        if wait_for_file_boundary; then
            log "at file boundary; proceeding"
        else
            log "no boundary within ${BOUNDARY_WAIT_SECS}s; rebooting anyway (costs one re-sent clip)"
        fi
    fi
fi

log "ACTION: no writes to cam disk for ${idle_s}s while gadget=configured, dashcam=${dcstate} (age ${dcage}s) (uptime $((uptime_s/60))m, archiving=${archiving}, ep1out errors this boot: ${ep1}) -> rebooting to reset dwc2"
if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would reboot now; cooldown marker not written"
    exit 0
fi
printf '%s' "$now" > "$STATE"
sync
"$REBOOT_CMD"
