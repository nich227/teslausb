#!/bin/bash
#
# sentry-keeper.sh — hold Sentry Mode on for the whole teslausb archive window.
#
# WHY: with SENTRY_CASE=2, teslausb's awake_start sends enable_sentry exactly
# once per archive cycle and never looks again, so anything that clears Sentry
# mid-cycle leaves it off until the *next* cycle starts. Two things do that
# routinely:
#
#   - Driving. Tesla cancels Sentry when the car shifts out of Park, so a short
#     trip during a cycle leaves Sentry off for the rest of it.
#
#   - The initial enable failing with {"result":false,"reason":"not_parked"}
#     because the car was still in R or D when the cycle began. awake_start logs
#     the failure and moves on; there is no retry.
#
# This matters beyond missing footage: Sentry is what keeps the car awake, and
# the car's USB port is what powers the Pi. Losing Sentry mid-transfer lets the
# car sleep, which cuts power to the Pi and kills the archive partway through.
#
# LIFECYCLE: started in the background by awake_start (SENTRY_CASE=2, Tessie
# backend), stopped by awake_stop before it sends disable_sentry. awake_stop
# kills it first specifically so it cannot race and re-arm Sentry after the cycle
# has ended.
#
# SAFETY:
#   - only ever *enables*, and only when the car is online and in Park, so it
#     cannot fight the car's own state machine or cause not_parked failures
#   - exits if its pid file disappears or is reassigned, so a keeper orphaned by
#     a failed kill cannot hold Sentry on indefinitely
#   - a hard runtime cap as a second backstop
#
set -uo pipefail

readonly INTERVAL="${SENTRY_KEEPER_INTERVAL:-300}"          # seconds between checks
readonly MAX_RUNTIME="${SENTRY_KEEPER_MAX_RUNTIME:-28800}"  # 8h backstop
readonly PIDFILE="${SENTRY_KEEPER_PIDFILE:-/tmp/sentry_keeper_pid}"
readonly LOG="${SENTRY_KEEPER_LOG:-/mutable/sentry-keeper.log}"
readonly SETUP_CONF="${SETUP_CONF:-/root/teslausb_setup_variables.conf}"
readonly API_BASE="${TESSIE_API_BASE:-https://api.tessie.com}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG"; }

# Credentials normally arrive in the environment from archiveloop, which sources
# the setup conf. Source it here too so the script also works standalone.
if [[ -z "${TESSIE_API_TOKEN:-}" || -z "${TESSIE_VIN:-}" ]]; then
    # shellcheck source=/dev/null
    [[ -r "$SETUP_CONF" ]] && source "$SETUP_CONF"
fi
if [[ -z "${TESSIE_API_TOKEN:-}" || -z "${TESSIE_VIN:-}" ]]; then
    log "ERROR: TESSIE_API_TOKEN/TESSIE_VIN not set; keeper exiting"
    exit 1
fi

readonly API="${API_BASE}/${TESSIE_VIN}"
readonly UA="github.com/marcone/teslausb"

tessie() {
    curl -s -m 30 \
        -H "Authorization: Bearer ${TESSIE_API_TOKEN}" \
        -H "Accept: application/json" \
        -H "User-Agent: ${UA}" \
        "$@"
}

started=$(date +%s)
log "keeper started (pid $$, interval ${INTERVAL}s)"

while sleep "$INTERVAL"; do
    # --- have we been orphaned or asked to stop? ---------------------------
    if [[ ! -e "$PIDFILE" ]] || [[ "$(cat "$PIDFILE" 2>/dev/null)" != "$$" ]]; then
        log "pid file gone or reassigned; keeper exiting"
        exit 0
    fi

    if (( $(date +%s) - started > MAX_RUNTIME )); then
        log "hit ${MAX_RUNTIME}s runtime cap; keeper exiting"
        rm -f "$PIDFILE"
        exit 0
    fi

    # --- what is the car doing? --------------------------------------------
    if ! state=$(tessie "${API}/state"); then
        log "state query failed (car offline or network down); will retry"
        continue
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$state"; then
        log "state response was not JSON; will retry"
        continue
    fi

    online=$(jq -r '.state // "unknown"' <<<"$state")
    # NB: `.x // "d"` is wrong for booleans — jq treats `false` as empty and
    # would report a cleared Sentry as "unknown". Test for null explicitly.
    sentry=$(jq -r 'if .vehicle_state.sentry_mode == null then "unknown"
                    else (.vehicle_state.sentry_mode | tostring) end' <<<"$state")
    shift_state=$(jq -r '.drive_state.shift_state // "P"' <<<"$state")

    [[ "$online" == "online" ]] || continue      # asleep/offline: cannot command
    [[ "$sentry" == "true" ]] && continue        # already armed: nothing to do
    [[ "$shift_state" == "P" ]] || continue      # moving: enable would fail with not_parked

    # --- re-arm ------------------------------------------------------------
    resp=$(tessie "${API}/command/enable_sentry")
    result=$(jq -r '.result // "unknown"' <<<"$resp" 2>/dev/null || echo unknown)
    if [[ "$result" == "true" ]]; then
        log "Sentry had been cleared (sentry=${sentry}, shift=${shift_state}); re-enabled"
    else
        reason=$(jq -r '.reason // "no reason given"' <<<"$resp" 2>/dev/null || echo "unparseable")
        log "re-enable failed: result=${result} reason=${reason}"
    fi
done
