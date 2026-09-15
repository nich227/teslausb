#!/bin/bash -e
#
# first-boot.sh - drives teslausb setup across the reboots it needs.
#
# DietPi has no /etc/rc.local, so this runs from teslausb-setup.service on every
# boot until setup reports itself finished. It is deliberately the only piece
# that has to exist before teslausb is installed, which is why the DietPi
# Automation_Custom_Script installs it first and then lets it take over.
#
# Networking is NOT touched here. DietPi owns the network: Wi-Fi credentials
# come from dietpi-wifi.txt or dietpi-config, and fighting dietpi-netcontrol
# over wpa_supplicant.conf is what breaks a working connection.

# Print the IP address, which is the only clue a headless user has
_IP=$(hostname -I) || true
if [ "$_IP" ]
then
  printf "My IP address is %s\n" "$_IP"
fi

# /teslausb points at the boot partition. DietPi mounts it at /boot on the
# boards teslausb runs on, but honour /boot/firmware if a future image splits
# it out the way Raspberry Pi OS did.
if [ ! -L /teslausb ]
then
  rm -rf /teslausb
  if [ -d /boot/firmware ] && findmnt --fstab /boot/firmware &> /dev/null
  then
    ln -s /boot/firmware /teslausb
  else
    ln -s /boot /teslausb
  fi
fi

if [ -f /teslausb/run_once ]
then
  cp /teslausb/run_once /tmp/
  chmod +x /tmp/run_once
  /tmp/run_once || echo "run_once failed"
  mv /teslausb/run_once /teslausb/ran_once || true
fi

SETUP_LOGFILE=/teslausb/teslausb-headless-setup.log

function write_all_leds {
  for led in /sys/class/leds/*
  do
    echo "$1" > "$led/$2" || true
  done &> /dev/null
}

function error_strobe () {
  modprobe ledtrig_timer || true
  write_all_leds timer trigger
  while true
  do
    write_all_leds 1 delay_on
    write_all_leds 100 delay_off
    sleep 1
    write_all_leds 0 delay_on
    sleep 1
  done
}

function setup_progress () {
  echo "$( date ) : $1" >> "$SETUP_LOGFILE" || echo "can't write to $SETUP_LOGFILE"
  echo "$1"
}

function get_script () {
  local local_path="$1"
  local name="$2"
  local remote_path="${3:-}"

  IFS=". " read -r start_time _ < /proc/uptime

  while ! curl -o "$local_path/$name" https://raw.githubusercontent.com/"$REPO"/teslausb/"$BRANCH"/"$remote_path"/"$name"
  do
    setup_progress "get_script failed, retrying"
    sntp -S time.google.com || true
    sleep 3
    IFS=". " read -r now _ < /proc/uptime
    if [ $((now - start_time)) -gt 60 ]
    then
      setup_progress "failed to get script after 60 seconds, exiting"
      return 1
    fi
  done
  chmod +x "$local_path/$name"
}

# Wait for the network before anything that needs it.
#
# The unit wants network-online.target, but on DietPi nothing necessarily waits
# on it: DietPi manages interfaces with ifupdown and systemd-networkd-wait-online
# is disabled, so the target can be reached while wifi is still associating. The
# device is in a car on wifi, so assume nothing and check.
function wait_for_network () {
  local waited=0
  local limit="${NETWORK_WAIT_SECONDS:-120}"

  while [ "$waited" -lt "$limit" ]
  do
    if ip route get 1.1.1.1 &> /dev/null
    then
      [ "$waited" -gt 0 ] && setup_progress "network came up after ${waited}s"
      return 0
    fi
    if [ "$waited" = 0 ]
    then
      setup_progress "waiting up to ${limit}s for the network"
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done

  setup_progress "WARNING: still no route to the network after ${limit}s; carrying on anyway"
  return 0
}

function safesource {
  cat <<EOF > /tmp/checksetupconf
#!/bin/bash -eu
source '$1' &> /tmp/checksetupconf.out
EOF
  chmod +x /tmp/checksetupconf
  if ! /tmp/checksetupconf
  then
    setup_progress "Error in $1:"
    setup_progress "$(cat /tmp/checksetupconf.out)"
    error_strobe &
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$1"
}

if [ -e "/teslausb/teslausb_setup_variables.conf" ]
then
  if [ -e /root/bin/remountfs_rw ]
  then
    /root/bin/remountfs_rw
  fi
  mv /teslausb/teslausb_setup_variables.conf /root/
  # DietPi does not ship dos2unix, and this script runs with -e, so fall back to
  # stripping the line endings directly rather than dying with the config file
  # already moved off the boot partition.
  if command -v dos2unix > /dev/null
  then
    dos2unix /root/teslausb_setup_variables.conf
  else
    setup_progress "dos2unix not installed, stripping CRLF line endings directly"
    sed -i 's/\r$//' /root/teslausb_setup_variables.conf
  fi
fi
if [ -e "/root/teslausb_setup_variables.conf" ]
then
  safesource /root/teslausb_setup_variables.conf
elif [ -e "/teslausb/teslausb_setup_variables.conf.sample" ]
then
  setup_progress "no config file found, but sample file is present."
else
  setup_progress "no config file found."
fi

function unblock_wifi () {
  # A soft-blocked radio never associates, so this has to happen before the
  # reboot that brings wifi up.
  #
  # The rfkill command cannot be relied on: rfkill is its own package on Bookworm
  # (it is not part of util-linux), Raspberry Pi OS Lite happens to ship it but
  # DietPi does not, and this runs before there is any network, so there is no
  # opportunity to apt-get it. Upstream's call was `|| true`-guarded and the fork
  # kept only that, so on DietPi a blocked radio stayed blocked silently.
  #
  # Both state stores are written, which is what upstream does:
  #   /sys/class/rfkill/*/soft        live kernel state, effective immediately
  #   /var/lib/systemd/rfkill/*:wlan  saved state that systemd-rfkill restores on
  #                                   the next boot, which is the boot that
  #                                   actually brings wifi up
  # Neither needs a package.
  local dev saved

  if command -v rfkill > /dev/null
  then
    rfkill unblock wifi &> /dev/null || true
  else
    for dev in /sys/class/rfkill/*
    do
      [ -e "$dev/type" ] || continue
      [ "$(cat "$dev/type" 2> /dev/null)" = "wlan" ] || continue
      echo 0 > "$dev/soft" 2> /dev/null || true
    done
  fi

  # Unlike upstream this checks the glob matched, so that when it does not the
  # shell cannot create a file literally named "*:wlan".
  for saved in /var/lib/systemd/rfkill/*:wlan
  do
    [ -e "$saved" ] || continue
    echo 0 > "$saved" 2> /dev/null || true
  done
}

# Wi-Fi, the plug-and-play way.
#
# SSID/WIFIPASS in teslausb_setup_variables.conf still work, exactly as they did
# on Raspberry Pi OS. The difference is how they are applied: instead of writing
# /etc/wpa_supplicant/wpa_supplicant.conf directly, which fights DietPi for the
# adapter, the credentials are handed to DietPi's own WiFi database and DietPi
# configures the adapter. Same config file, same one-reboot behaviour, no
# conflict.
#
# For a device with no ethernet, put the credentials on the boot partition
# before first boot (dietpi.txt plus dietpi-wifi.txt, or run
# tools/prepare-boot-partition.sh), because DietPi needs the network during its
# own first boot, which happens before this script ever runs.
function enable_wifi () {
  if [ -z "${SSID:-}" ] || [ -z "${WIFIPASS:-}" ]
  then
    setup_progress "skipping wifi setup because SSID/WIFIPASS were not specified"
    return 0
  fi

  if [ -e /teslausb/WIFI_ENABLED ]
  then
    return 0
  fi

  if [ ! -x /boot/dietpi/func/dietpi-wifidb ]
  then
    setup_progress "WARNING: dietpi-wifidb not found, leaving wifi to DietPi"
    return 0
  fi

  if [ -x /root/bin/remountfs_rw ]
  then
    /root/bin/remountfs_rw
  fi

  setup_progress "Handing wifi credentials for '$SSID' to DietPi"

  # DietPi reads slot 0..4 from this file and moves it into its own database.
  cat > /boot/dietpi-wifi.txt <<EOF
aWIFI_SSID[0]='${SSID}'
aWIFI_KEY[0]='${WIFIPASS}'
aWIFI_KEYMGR[0]='WPA-PSK'
EOF
  chmod 600 /boot/dietpi-wifi.txt

  # Make sure DietPi keeps wifi enabled across its own reconfiguration.
  if [ -f /boot/dietpi.txt ]
  then
    if grep -q '^AUTO_SETUP_NET_WIFI_ENABLED=' /boot/dietpi.txt
    then
      sed -i 's/^AUTO_SETUP_NET_WIFI_ENABLED=.*/AUTO_SETUP_NET_WIFI_ENABLED=1/' /boot/dietpi.txt
    else
      echo "AUTO_SETUP_NET_WIFI_ENABLED=1" >> /boot/dietpi.txt
    fi
  fi

  # Load the wifi drivers, then let DietPi apply the credentials.
  if [ -x /boot/dietpi/func/dietpi-set_hardware ]
  then
    /boot/dietpi/func/dietpi-set_hardware wifimodules enable || \
      setup_progress "WARNING: could not enable the wifi modules"
  fi

  if ! /boot/dietpi/func/dietpi-wifidb 1
  then
    setup_progress "WARNING: DietPi could not apply the wifi credentials"
  fi

  # Set the host name now so it takes effect on the reboot below.
  if [ -n "${TESLAUSB_HOSTNAME:-}" ]
  then
    local old_host_name
    old_host_name=$(cat /etc/hostname)
    if [ "$TESLAUSB_HOSTNAME" != "$old_host_name" ] && [ -x /boot/dietpi/func/change_hostname ]
    then
      /boot/dietpi/func/change_hostname "$TESLAUSB_HOSTNAME" || \
        setup_progress "WARNING: could not change the host name"
    fi
  fi

  unblock_wifi

  touch /teslausb/WIFI_ENABLED
  setup_progress "Rebooting to bring up wifi..."
  exec reboot
}

enable_wifi

# If the FINISHED file does not exist then start setup, otherwise there is
# nothing to do: teslausb itself runs as its own systemd service.
if [ ! -e "/teslausb/TESLAUSB_SETUP_FINISHED" ]
then
  if [ -e /root/bin/remountfs_rw ]
  then
    /root/bin/remountfs_rw
  fi
  touch "/teslausb/TESLAUSB_SETUP_STARTED"

  if [ -e "/root/teslausb_setup_variables.conf" ]
  then
    source "/root/teslausb_setup_variables.conf"
  else
    # No conf file found, can't complete setup
    setup_progress "Setup appears not to have completed, but you didn't provide a teslausb_setup_variables.conf."
  fi

  if [ ! -d "/root/bin" ]
  then
    mkdir "/root/bin"
  fi

  # A staged copy of the sources on the boot partition wins over GitHub. This is
  # what makes an offline install possible, and it is how the VM test exercises
  # the working tree rather than whatever happens to be published. teslausb's own
  # copy_script skips downloading entirely when SOURCE_DIR is set.
  if [ -f /boot/teslausb-local/repo.tar ]
  then
    setup_progress "Using the sources staged in /boot/teslausb-local/repo.tar"
    rm -rf /root/teslausb-src
    mkdir -p /root/teslausb-src
    if tar -xf /boot/teslausb-local/repo.tar -C /root/teslausb-src
    then
      export SOURCE_DIR=/root/teslausb-src
      if [ -f "$SOURCE_DIR/setup/pi/setup-teslausb" ]
      then
        install -m 755 "$SOURCE_DIR/setup/pi/setup-teslausb" /root/bin/setup-teslausb
      fi
    else
      setup_progress "WARNING: could not unpack the staged sources; falling back to GitHub"
      rm -rf /root/teslausb-src
    fi
  fi

  if [ ! -e "/root/bin/setup-teslausb" ]
  then
    REPO=${REPO:-nich227}
    BRANCH=${BRANCH:-main-dev}
    wait_for_network
    setup_progress "Grabbing main setup file."
    if ! get_script /root/bin setup-teslausb setup/pi
    then
      setup_progress "Failed to retrieve setup script. Check that DietPi has a working network connection."
      error_strobe &
      exit 0
    fi
  fi

  setup_progress "Starting setup."

  # Start setup. This should take us all the way through to reboot
  if ! /root/bin/setup-teslausb
  then
    error_strobe &
    exit 0
  fi

  # reboot for good measure, which also re-runs this script
  exec reboot
fi

exit 0
