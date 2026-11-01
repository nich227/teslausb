#!/bin/bash

# Run the SD card at 100 MHz instead of 50, when the card has shown it can.
#
# WHY: the car reads its recordings back through the Pi, and on the Zero 2 W and
# Pi 3 the SD bus, not USB, is the ceiling. The firmware clocks it at 50 MHz, which
# is 23 MB/s measured; sd_overclock=100 roughly doubles that, so a minute of
# four-camera footage reaches the car in half the time.
#
# NOT EVERY CARD TAKES IT. A card that cannot run at 100 MHz corrupts what is
# written to it, or does not respond at all, in which case the kernel cannot read
# the root filesystem and the device never finishes booting. In a car nobody can
# pull the card and fix config.txt, so the clock is never written there directly.
#
# HOW: the setting goes into tryboot.txt, and the device reboots once with the
# firmware's tryboot flag, which loads that file instead of config.txt for one
# boot only. If the kernel does not come up, the next power cycle is an ordinary
# boot from the untouched config.txt. If it does come up, this verifies the card
# before anything else touches it: the clock really changed, a sample of the card
# reads back identical to a checksum taken at the old clock, data written now reads
# back intact, and the kernel logged no SD errors. Only then is tryboot.txt made
# the config.txt. A failed check reverts and reboots.
#
# THE CAR WAITS: the unit runs before teslausb.service, so the drive is not offered
# to the car until the card has passed, and a failing trial never records footage.
#
# WHICH CARDS: auto mode tries only cards sold for continuous recording, since
# those are what belongs in a dashcam anyway, and only the ones whose identity is
# known for certain. Setting SD_OVERCLOCK=true tries any card, still verified.
#
# WHICH BOARDS: only the bcm2835-sdhost controller honours sd_overclock. The Pi 4
# and 5 use a different one that ignores it, and already run the bus at DDR50.
#
# Usage: teslausb-sd-overclock configure <auto|true|false>   from setup
#        teslausb-sd-overclock boot                           from the unit
#        teslausb-sd-overclock status

set -u

readonly STATE_DIR="${STATE_DIR:-/mutable/sd-overclock}"
readonly STATE_FILE="$STATE_DIR/state"
readonly LOG_FILE="$STATE_DIR/log"
readonly SAMPLE_SUM="$STATE_DIR/sample.sha256"
readonly SPEED_FILE="$STATE_DIR/speed"
readonly BOOT_DIR="${BOOT_DIR:-/boot/firmware}"
readonly CONFIG_TXT="$BOOT_DIR/config.txt"
readonly TRYBOOT_TXT="$BOOT_DIR/tryboot.txt"
readonly SYS_BLOCK="${SYS_BLOCK:-/sys/block/mmcblk0}"
readonly MMC_HOST="${MMC_HOST:-mmc0}"
readonly MMC_IOS="${MMC_IOS:-/sys/kernel/debug/$MMC_HOST/ios}"
readonly TRYBOOT_FLAG="${TRYBOOT_FLAG:-/proc/device-tree/chosen/bootloader/tryboot}"
readonly REBOOT_PARAM="${REBOOT_PARAM:-/run/systemd/reboot-param}"
readonly DROP_CACHES="${DROP_CACHES:-/proc/sys/vm/drop_caches}"
readonly SAMPLE_DEV="${SAMPLE_DEV:-/dev/mmcblk0p2}"
readonly SAMPLE_MB="${SAMPLE_MB:-128}"
readonly WRITE_MB="${WRITE_MB:-32}"
readonly DD_FLAGS="${DD_FLAGS-iflag=direct}"
readonly CLOCK_MHZ=100
readonly MARK='# teslausb: a faster SD card clock, verified on this card'
readonly LINE="dtparam=sd_overclock=$CLOCK_MHZ"

log () {
  mkdir -p "$STATE_DIR"
  echo "$(date '+%F %T'): $*" | tee -a "$LOG_FILE"
}

state () { cat "$STATE_FILE" 2> /dev/null; }

set_state () {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$STATE_FILE"
}

# The boot partition is mounted read-only. Remount it for a write and put it back
# as it was, since during setup it is already writable and stays that way.
boot_was_ro=
boot_rw () {
  mountpoint -q "$BOOT_DIR" || return 0
  if findmnt -no OPTIONS "$BOOT_DIR" | tr , '\n' | grep -qx ro
  then
    boot_was_ro=1
    mount -o remount,rw "$BOOT_DIR"
  fi
}
boot_restore () {
  [ -n "$boot_was_ro" ] && mount -o remount,ro "$BOOT_DIR"
  boot_was_ro=
}

has_line () { grep -qxF "$LINE" "$1" 2> /dev/null; }
has_mark () { grep -qxF "$MARK" "$1" 2> /dev/null; }

# config.txt with the setting at the very top. A dtparam applies to whatever
# dtoverlay came before it, and a line below a [model] filter applies to that
# model only; the first lines of the file are under neither.
with_line () {
  printf '%s\n%s\n' "$MARK" "$LINE"
  cat "$CONFIG_TXT"
}

without_line () {
  grep -vxF -e "$MARK" -e "$LINE" "$CONFIG_TXT"
}

write_boot_file () {
  # $1 destination, stdin content
  boot_rw
  cat > "$1.new" && mv -f "$1.new" "$1"
  boot_restore
}

remove_tryboot () {
  [ -e "$TRYBOOT_TXT" ] || return 0
  boot_rw
  rm -f "$TRYBOOT_TXT"
  boot_restore
}

card_identity () {
  manfid=$(cat "$SYS_BLOCK/device/manfid" 2> /dev/null)
  oemid=$(cat "$SYS_BLOCK/device/oemid" 2> /dev/null)
  name=$(cat "$SYS_BLOCK/device/name" 2> /dev/null)
  identity="${name:-unknown} (manufacturer ${manfid:-?}, oem ${oemid:-?})"
}

# Cards made for continuous recording, by the identity they report. SanDisk is
# manufacturer 0x03 with OEM "SD", and its High Endurance line names itself SH
# followed by the capacity. Other makers' endurance lines are not listed because
# what they report has not been confirmed; SD_OVERCLOCK=true covers them.
high_endurance () {
  case "$manfid/$oemid/$name" in
    0x000003/0x5344/SH*) return 0 ;;
  esac
  return 1
}

sdhost () {
  tr '\0' '\n' < "$SYS_BLOCK/device/../../../of_node/compatible" 2> /dev/null | grep -qx 'brcm,bcm2835-sdhost'
}

actual_mhz () {
  local hz
  hz=$(sed -n 's/^actual clock:[[:space:]]*\([0-9]*\) Hz.*/\1/p' "$MMC_IOS" 2> /dev/null)
  echo "$(( ${hz:-0} / 1000000 ))"
}

tryboot_active () {
  [ "$(od -An -tu4 --endian=big "$TRYBOOT_FLAG" 2> /dev/null | tr -d ' ')" = "1" ]
}

# Checksum of the first SAMPLE_MB of the root partition, read from the card and not
# the page cache. The root filesystem is mounted read-only, so the same bytes are
# there at both clocks. The speed dd reports is kept to show what changed.
sample_sha=
sample_speed=
read_sample () {
  # shellcheck disable=SC2086 # DD_FLAGS is meant to split, and may be empty
  sample_sha=$(LC_ALL=C dd if="$SAMPLE_DEV" bs=1M count="$SAMPLE_MB" $DD_FLAGS 2> "$STATE_DIR/dd.err" | sha256sum | cut -d' ' -f1)
  sample_speed=$(sed -n 's/.*, \([0-9.]* [GM]B\/s\)$/\1/p' "$STATE_DIR/dd.err" | tail -1)
  rm -f "$STATE_DIR/dd.err"
}

# Write fresh random data, push it out to the card, drop the cache and read it back.
write_test () {
  local scratch="$STATE_DIR/scratch" expected actual
  if ! head -c "$(( WRITE_MB * 1048576 ))" /dev/urandom > "$scratch" || ! sync "$scratch"
  then
    rm -f "$scratch"
    return 1
  fi
  expected=$(sha256sum < "$scratch" | cut -d' ' -f1)
  echo 3 > "$DROP_CACHES" 2> /dev/null
  # shellcheck disable=SC2086
  actual=$(LC_ALL=C dd if="$scratch" bs=1M $DD_FLAGS 2> /dev/null | sha256sum | cut -d' ' -f1)
  rm -f "$scratch"
  [ "$expected" = "$actual" ]
}

mmc_errors () {
  dmesg 2> /dev/null | grep -ciE "$MMC_HOST: .*(error|timeout|crc)"
}

# --- configure: decide, at setup, whether this device should try at all -----------
cmd_configure () {
  local mode="${1:-auto}" current
  current=$(state)
  card_identity

  if [ "$mode" = false ]
  then
    remove_tryboot
    if has_mark "$CONFIG_TXT"
    then
      without_line | write_boot_file "$CONFIG_TXT"
      log "SD_OVERCLOCK=false: removed $LINE from config.txt; the card runs at the standard clock from the next boot"
    fi
    set_state disabled
    return 0
  fi
  if [ "$mode" != auto ] && [ "$mode" != true ]
  then
    log "SD_OVERCLOCK=$mode is not one of auto, true or false; leaving the SD clock alone"
    return 0
  fi

  if ! sdhost
  then
    set_state unsupported
    log "this board's SD controller does not take sd_overclock; nothing to do"
    return 0
  fi

  if has_line "$CONFIG_TXT" && ! has_mark "$CONFIG_TXT"
  then
    set_state manual
    log "config.txt already sets $LINE by hand; leaving it alone"
    return 0
  fi

  case "$current" in
    enabled|trying)
      log "SD clock already $current for $identity"
      return 0
      ;;
    failed*)
      if [ "$mode" = auto ]
      then
        log "a previous trial on $identity $current; set SD_OVERCLOCK=true to try again"
        return 0
      fi
      ;;
  esac

  if [ "$mode" = auto ] && ! high_endurance
  then
    set_state "skipped: $identity is not a card known to be made for continuous recording"
    log "not trying $CLOCK_MHZ MHz on $identity: not a card known to be made for continuous recording. SD_OVERCLOCK=true tries it anyway"
    return 0
  fi

  set_state pending
  log "$identity will be tried at $CLOCK_MHZ MHz on the next boot"
}

# --- boot: the state machine, one step per boot ----------------------------------
fail_trial () {
  # $1 reason. Back to config.txt as it was, which the next boot loads.
  remove_tryboot
  set_state "failed: $1"
  log "trial at $CLOCK_MHZ MHz failed: $1. Keeping the standard clock and rebooting"
  systemctl reboot
}

cmd_boot () {
  local current mhz
  current=$(state)
  case "$current" in
    pending)
      mkdir -p "$STATE_DIR"
      read_sample
      echo "$sample_sha" > "$SAMPLE_SUM"
      echo "$sample_speed" > "$SPEED_FILE"
      log "at $(actual_mhz) MHz the card reads at ${sample_speed:-an unknown speed}; trying $CLOCK_MHZ MHz with one tryboot"
      with_line | write_boot_file "$TRYBOOT_TXT"
      set_state trying
      echo "0 tryboot" > "$REBOOT_PARAM"
      systemctl reboot
      ;;
    trying)
      if ! tryboot_active
      then
        remove_tryboot
        set_state "failed: the trial boot did not complete, so the card may not boot at $CLOCK_MHZ MHz, or power was lost during it"
        log "this is not the trial boot, so the trial at $CLOCK_MHZ MHz did not complete. Keeping the standard clock"
        return 0
      fi
      mhz=$(actual_mhz)
      if [ "$mhz" -le 50 ]
      then
        fail_trial "the clock is still $mhz MHz, so the setting had no effect here"
        return 0
      fi
      read_sample
      if [ "$sample_sha" != "$(cat "$SAMPLE_SUM" 2> /dev/null)" ]
      then
        fail_trial "data on the card read back differently at $mhz MHz"
        return 0
      fi
      if ! write_test
      then
        fail_trial "data written at $mhz MHz did not read back the same"
        return 0
      fi
      if [ "$(mmc_errors)" != 0 ]
      then
        fail_trial "the kernel logged $(mmc_errors) SD errors at $mhz MHz"
        return 0
      fi
      boot_rw
      mv -f "$TRYBOOT_TXT" "$CONFIG_TXT"
      boot_restore
      set_state enabled
      log "verified at $mhz MHz: the card reads at ${sample_speed:-?}, was $(cat "$SPEED_FILE" 2> /dev/null). Kept in config.txt"
      rm -f "$SAMPLE_SUM"
      ;;
    enabled)
      if ! has_line "$CONFIG_TXT"
      then
        log "config.txt lost $LINE; restoring the verified setting"
        with_line | write_boot_file "$CONFIG_TXT"
      fi
      ;;
  esac
}

cmd_status () {
  card_identity
  echo "state: $(state)"
  echo "card: $identity"
  echo "clock: $(actual_mhz) MHz"
}

case "${1:-}" in
  configure) cmd_configure "${2:-auto}" ;;
  boot) cmd_boot ;;
  status) cmd_status ;;
  *) echo "usage: ${0##*/} configure <auto|true|false> | boot | status" >&2; exit 2 ;;
esac
