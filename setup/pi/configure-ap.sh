#!/bin/bash -eu

# based on https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

if [ -z "${AP_SSID+x}" ]
then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8))
then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

# The access point is built on NetworkManager. DietPi manages the network with
# ifupdown and wpa_supplicant by default, so NetworkManager has to be in charge
# before this can work; running both leaves the wifi client connection broken.
# Rather than switching the network stack out from under a working install, stop
# here and say what to do.
if ! systemctl -q is-enabled NetworkManager.service 2> /dev/null
then
  log_progress "STOP: AP_SSID is set, but NetworkManager is not managing the network."
  log_progress "The teslausb access point needs NetworkManager, while DietPi defaults to"
  log_progress "ifupdown plus wpa_supplicant. Either hand networking over to"
  log_progress "NetworkManager first ('apt install network-manager', move your wifi"
  log_progress "settings across, reboot), or remove AP_SSID from"
  log_progress "teslausb_setup_variables.conf and configure wifi with dietpi-config"
  log_progress "(Network Options: Adapters) instead."
  exit 1
fi

function nm_get_wifi_client_device () {
  for _ in {1..5}
  do
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN" ]
    then
      break;
    fi
    log_progress "Waiting for wifi interface to come back up"
    sleep 5
  done

  [ -n "$WLAN" ] && return 0

  log_progress "Couldn't determine wifi client device"
  nmcli c show
  return 1
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  if ! iw dev ap0 info &> /dev/null
  then
    # create additional virtual interface for the wifi device
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  # turn off power savings for both interfaces since they use
  # the same underlying hardware, and we don't want one to go
  # into power save mode just because the other is idle
  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  # set up access point on the virtual interface using networkmanager
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  # don't set band and channel, because that is controlled by the $WLAN interface
  #nmcli con modify TESLAUSB_AP 802-11-wireless.band bg
  #nmcli con modify TESLAUSB_AP 802-11-wireless.channel 6
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$WLAN" ]
then
  iw dev $WLAN interface add ap0 type __ap
  iw "$WLAN" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi

EOF
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
}


# force-install iw because otherwise it will get autoremoved when
# alsa-utils is removed later
apt-get -y install iw || exit 1

if ! nm_add_ap
then
  # Network Manager won't allow adding connections when started with a
  # read-only root fs, even if the root fs is not writeable, so try
  # again after restarting Network Manager
  log_progress "Retrying after restarting Network Manager"
  systemctl restart NetworkManager.service
  if ! nm_add_ap
  then
    log_progress "STOP: Failed to configure AP"
    exit 1
  fi
fi

log_progress "AP configured"
exit 0
