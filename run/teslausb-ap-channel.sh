#!/bin/bash -eu

# Pick the least congested 2.4GHz channel for the teslausb access point.
#
# WHAT THIS CAN AND CANNOT DO
#
# The radio in a Pi Zero 2 W (and the other brcmfmac parts) allows one channel
# for the whole device. From `iw list`:
#
#   #{ managed } <= 1, #{ AP } <= 1, ... total <= 4, #channels <= 1
#
# So while wlan0 is associated to a network, the access point has no channel of
# its own: it must sit on whatever channel that network uses, which is what
# teslausb-ap-up arranges. Choosing a channel is therefore only possible when
# there is no client association, and that is the case that matters, because it
# is when the access point is the only way to reach the device.
#
# When it cannot act it still reports what it would have chosen, so the channel
# the home network uses can be judged from where the device actually sits. That
# is the only lever at home, and it belongs to the router, not to this script.
#
# HOW A CHANNEL IS SCORED
#
# brcmfmac reports no survey data, so there is no airtime-busy figure to read and
# the neighbours themselves are the only available signal.
#
# WHY NOT hostapd's ACS, WHICH IS THE OBVIOUS ANSWER
#
# ACS (channel=0) is the native way to do this and it is compiled into Debian's
# hostapd 2.10. It does not work on this hardware, and the failure is quiet enough
# to be worth writing down. With channel=0, hostapd 2.10 on a Pi Zero 2 W logs:
#
#   ACS: Automatic channel selection started, this may take a bit
#   ACS: Using survey based algorithm (acs_num_scans=5)
#   nl80211: Fetch survey data
#   ap0: Event SURVEY (46) received
#   No survey data received
#   ACS: Scanning 2 / 5
#
# and after the last scan it gives up and the interface never comes up, because
# the survey based algorithm is the only one it has and brcmfmac fills in nothing.
# `iw dev wlan0 survey dump` is empty on this part for the same reason. So the
# choice is scan-and-score here, or a fixed channel.
#
# DFS and ieee80211h do not apply either: this radio advertises 14 channels in
# 2.4GHz and none in 5GHz, and radar avoidance is a 5GHz concern.
#
# Channel hopping while clients are connected is also deliberately not done here.
# Routers pick at boot and then stay put, moving only for radar, because a channel
# change drops every associated station. This runs hourly and only acts when the
# radio is free, which on this device also means no client is relying on it.
#
# For each candidate, every neighbouring BSS within four channels contributes,
# because 2.4GHz channels are 20MHz wide but spaced 5MHz apart, so they overlap
# rather than being discrete. Contributions are summed as linear power converted
# from dBm, since dBm is logarithmic and adding it directly would let a handful of
# distant APs outweigh one loud neighbour.
#
# Usage:
#   teslausb-ap-channel best     print the best channel, or the client's channel
#                                when the radio is pinned to it
#   teslausb-ap-channel report   print the full scoring table
#   teslausb-ap-channel apply    restart the access point onto the best channel,
#                                but only when there is no client association and
#                                the channel would actually change

readonly AP_IFACE=ap0
PATH="/usr/sbin:/sbin:$PATH"

function log_msg () {
  # Plain stdout: systemd captures it into the journal for the oneshot service
  # that drives this, it is readable when run by hand, and it stays visible to the
  # tests. Routing through logger instead hid the output from all three.
  echo "$1"
}

# The client interface is whichever wifi interface is not the access point.
function client_iface () {
  iw dev 2> /dev/null | awk '/Interface/ {print $2}' | grep -v "^${AP_IFACE}$" | head -1
}

function client_channel () {
  local iface="$1" freq
  freq=$(iw dev "$iface" link 2> /dev/null | awk '/freq/ {print $2; exit}')
  [ -n "${freq:-}" ] || return 1
  # 2.4GHz only; the access point is hw_mode=g
  [ "$freq" -lt 2500 ] || return 1
  echo $(( (freq - 2407) / 5 ))
}

function ap_channel () {
  iw dev "$AP_IFACE" info 2> /dev/null | awk '/channel/ {print $2; exit}'
}

# Scan and emit "channel score" per candidate, best first. Scanning is done on the
# client interface even when it is not associated; it does not disturb an access
# point running on the same radio.
#
# The scores are computed once and cached in a file for the life of the process.
# Scanning more than once per invocation gave inconsistent answers, because the air
# changes between scans: on real hardware the report labelled one channel quietest
# while the table printed beside it disagreed, the two having come from separate
# scans. A file rather than a variable, because the callers read this through
# pipelines, and a variable set inside a subshell would not survive.
SCORES_FILE=""
function score_channels () {
  local iface="$1" scan
  if [ -n "$SCORES_FILE" ] && [ -s "$SCORES_FILE" ]
  then
    cat "$SCORES_FILE"
    return 0
  fi

  scan=$(mktemp)
  # A scan can fail transiently while the radio is busy, so give it a few goes.
  local tries=0
  until timeout 30 iw dev "$iface" scan > "$scan" 2> /dev/null
  do
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 3 ]
    then
      rm -f "$scan"
      return 1
    fi
    sleep 5
  done

  awk '
    /^BSS/                { freq = ""; sig = "" }
    /freq:/               { freq = $2 }
    /signal:/             { sig = $2 }
    /SSID:/               { if (freq != "" && sig != "" && freq < 2500) { n++; f[n] = freq; s[n] = sig } }
    END {
      for (ch = 1; ch <= 11; ch++) {
        total = 0
        for (i = 1; i <= n; i++) {
          nch = (f[i] - 2407) / 5
          dist = ch - nch; if (dist < 0) dist = -dist
          if (dist > 4) continue
          overlap = (5 - dist) / 5
          total += overlap * exp(log(10) * s[i] / 10)
        }
        printf "%d %.6e\n", ch, total
      }
    }
  ' "$scan" | sort -k2 -g > "$SCORES_FILE"
  rm -f "$scan"
  [ -s "$SCORES_FILE" ] || return 1
  cat "$SCORES_FILE"
}

function best_channel () {
  local iface="$1"
  score_channels "$iface" | head -1 | awk '{print $1}'
}

iface=$(client_iface)
if [ -z "${iface:-}" ]
then
  log_msg "no wifi interface found"
  exit 1
fi

# One scan per invocation, shared by every reader below.
SCORES_FILE=$(mktemp)
trap 'rm -f "$SCORES_FILE"' EXIT

pinned=""
if pinned_ch=$(client_channel "$iface")
then
  pinned="$pinned_ch"
fi

case "${1:-best}" in
  best)
    if [ -n "$pinned" ]
    then
      # Radio is pinned by the client association; report that channel.
      echo "$pinned"
    else
      best_channel "$iface" || exit 1
    fi
    ;;

  report)
    echo "client interface : $iface"
    if [ -n "$pinned" ]
    then
      echo "client channel   : $pinned (radio pinned here, the AP cannot differ)"
    else
      echo "client channel   : not associated (the AP is free to choose)"
    fi
    echo "AP channel now   : $(ap_channel || echo 'AP not up')"
    echo
    printf '%-4s %-14s %s\n' "ch" "score" "note"
    best=$(score_channels "$iface" | head -1 | awk '{print $1}')
    score_channels "$iface" | sort -n -k1 | while read -r ch score
    do
      note=""
      [ "$ch" = "${best:-}" ] && note="least interference"
      [ "$ch" = "${pinned:-}" ] && note="${note:+$note, }current (pinned by client)"
      printf '%-4s %-14s %s\n' "$ch" "$score" "$note"
    done
    ;;

  apply)
    if [ -n "$pinned" ]
    then
      best=$(best_channel "$iface" || echo "")
      log_msg "client associated on channel $pinned, so the AP cannot move; the least congested channel from here is ${best:-unknown} (change the router to benefit)"
      exit 0
    fi
    best=$(best_channel "$iface") || { log_msg "scan failed, leaving the channel alone"; exit 0; }
    current=$(ap_channel || echo "")
    if [ "${current:-}" = "$best" ]
    then
      log_msg "AP already on the least congested channel ($best)"
      exit 0
    fi
    log_msg "moving the AP from channel ${current:-unknown} to $best"
    # teslausb-ap-up recomputes the runtime config on every start, and reads this
    # same choice, so restarting is enough to land on the new channel.
    systemctl restart teslausb-ap.service
    ;;

  *)
    echo "usage: ${0##*/} [best|report|apply]" >&2
    exit 1
    ;;
esac
