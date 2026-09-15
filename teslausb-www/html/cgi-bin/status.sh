#!/bin/bash
# shellcheck disable=SC2016
# SC2016 shellcheck wants double quotes for the free/used space calculation
# below, but that requires additional ugly escaping

if [[ -e /sys/kernel/config/usb_gadget/teslausb ]]
then
  drives_active=yes
else
  drives_active=no
fi

readarray -t snapshots < <(find /backingfiles/snapshots/ -name snap.bin 2> /dev/null | sort)
readonly numsnapshots=${#snapshots[@]}
if [[ "$numsnapshots" != "0" ]]
then
  oldestsnapshot=$(stat --format="%Y" "${snapshots[0]}")
  newestsnapshot=$(stat --format="%Y" "${snapshots[-1]}")
fi

wifidev=$(find /sys/class/net/ -type l -name 'wl*' -printf '%P' -quit)

if [ -n "$wifidev" ]
then
  wifi_ssid=$(iwgetid -r "$wifidev" || true)
  wifi_freq=$(iwgetid -r -f "$wifidev" || true)
  wifi_strength=$(iwconfig "$wifidev" | grep "Link Quality" | sed 's/ *Link Quality=\([0-9]*\)\/\([0-9]*\)\(.*\)/\1\/\2/')
  read -r _ wifi_ip _ < <(ifconfig "$wifidev" | grep "inet ")
else
  wifi_ssid=
  wifi_freq=
  wifi_strength=
  wifi_ip=
fi

ethdev=$(find /sys/class/net/ -type l \( -name 'eth*' -o -name 'en*' \) -printf '%P' -quit)

if [ -n "$ethdev" ]
then
  read -r _ ether_ip _ < <(ifconfig "$ethdev" | grep "inet ")
  IFS=" :" read -r _ ether_speed < <(ethtool "$ethdev" 2>&1 | grep Speed)
else
  ether_ip=
  ether_speed=
fi

read -r -d ' ' ut < /proc/uptime

# Access point, when one is configured. Everything here stays empty if the AP is
# not running, so the dashboard can simply hide the panel. `iw` lives in /usr/sbin,
# which is not on the CGI process's PATH.
readonly IW=/usr/sbin/iw
ap_ssid=""
ap_channel=""
ap_ip=""
ap_clients=""
if [ -d /sys/class/net/ap0 ]
then
  ap_ssid=$("$IW" dev ap0 info 2> /dev/null | sed -n 's/^\s*ssid \(.*\)$/\1/p')
  ap_channel=$("$IW" dev ap0 info 2> /dev/null | sed -n 's/^\s*channel \([0-9]*\).*/\1/p')
  ap_ip=$(ip -4 -br addr show ap0 2> /dev/null | awk '{print $3}' | cut -d/ -f1)
  # One line per associated station. grep -c already prints 0 when it matches
  # nothing, and exits 1 while doing so, so a `|| echo 0` fallback would append a
  # second line and put a newline inside the JSON value.
  ap_clients=$("$IW" dev ap0 station dump 2> /dev/null | grep -c '^Station') || true
  [ -n "$ap_clients" ] || ap_clients=0
fi

fan_speed=$(cat /sys/devices/platform/cooling_fan/hwmon/*/fan1_input 2>/dev/null || echo "N/A")

external_5v=$(sudo -n vcgencmd pmic_read_adc EXT5V_V 2>/dev/null) && external_5v=${external_5v##*=} && external_5v=${external_5v%V} || external_5v="N/A"
rtc_batt_v=$(sudo -n vcgencmd pmic_read_adc BATT_V 2>/dev/null) && rtc_batt_v=${rtc_batt_v##*=} && rtc_batt_v=${rtc_batt_v%V} || rtc_batt_v="N/A"

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{
   "cpu_temp": "$(cat /sys/class/thermal/thermal_zone0/temp)",
   "fan_speed": "$fan_speed",
   "external_5v": "$external_5v",
   "throttled": "$(sudo -n vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p' || echo "N/A")",
   "rtc_batt_v": "$rtc_batt_v",
   "num_snapshots": "$numsnapshots",
   "snapshot_oldest": "$oldestsnapshot",
   "snapshot_newest": "$newestsnapshot",
   $(eval "$(stat --file-system --format='echo -e \"total_space\": \"$((%b*%S))\",\\\n\ \ \ \"free_space\": \"$((%f*%S))\",' /backingfiles/.)")
   "uptime": "$ut",
   "drives_active": "$drives_active",
   "wifi_ssid": "$wifi_ssid",
   "wifi_freq": "$wifi_freq",
   "wifi_strength": "$wifi_strength",
   "wifi_ip": "$wifi_ip",
   "ether_ip": "$ether_ip",
   "ether_speed": "$ether_speed",
   "ap_ssid": "$ap_ssid",
   "ap_channel": "$ap_channel",
   "ap_ip": "$ap_ip",
   "ap_clients": "$ap_clients"
}
EOF
