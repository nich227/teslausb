#!/bin/bash -eu

# The teslausb access point, so the device is reachable in a car that is nowhere
# near the home network.
#
# Two things share one radio: the client connection that DietPi manages on wlan0,
# and the access point. That is done with a second virtual interface, ap0, on the
# same PHY, which is the arrangement described at
# https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/
#
# hostapd and dnsmasq run the access point, which is how DietPi runs its own
# hotspot. This deliberately does not use NetworkManager: DietPi manages the
# network with ifupdown and wpa_supplicant, and installing NetworkManager to get an
# access point means handing wlan0 to a different manager mid-install, migrating
# the credentials and rebooting to finish. A device in a car that comes back from
# that reboot without wifi is unreachable, and the whole point of the access point
# is to be reachable. Running hostapd on ap0 leaves wlan0 exactly where it was.
#
# The AP follows the client's channel, because both interfaces share one radio and
# cannot be on two channels at once.

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

readonly AP_ADDRESS="${AP_IP:-192.168.66.1}"
# The DHCP pool sits in the same /24 as the access point's own address.
AP_SUBNET="${AP_ADDRESS%.*}"
readonly AP_SUBNET
# US unless the config says otherwise, matching what teslausb has always assumed
# for wifi. The "world" placeholder 00 that DietPi's own hotspot writes is not
# usable: hostapd refuses to start with "Invalid country_code '00'", so anything
# that is not a pair of letters becomes US.
AP_COUNTRY="${WIFI_COUNTRY:-US}"
case "$AP_COUNTRY" in
  [A-Za-z][A-Za-z]) AP_COUNTRY=$(printf '%s' "$AP_COUNTRY" | tr '[:lower:]' '[:upper:]') ;;
  *) AP_COUNTRY=US ;;
esac
readonly AP_COUNTRY

# The template lives on the root filesystem, which is read-only in normal
# operation. The copy hostapd actually reads is generated on tmpfs at start, with
# the channel filled in, because the channel is only known once the client has
# associated.
readonly AP_CONF=/etc/hostapd/teslausb-ap.conf
readonly AP_RUNTIME_CONF=/run/teslausb-ap.conf
readonly AP_DNSMASQ=/etc/dnsmasq.d/teslausb-ap.conf
readonly AP_UP=/usr/local/bin/teslausb-ap-up
readonly AP_UNIT=/etc/systemd/system/teslausb-ap.service

# iw is force-installed because it would otherwise be autoremoved along with
# alsa-utils later in setup.
log_progress "installing hostapd, dnsmasq and iw"
DEBIAN_FRONTEND=noninteractive apt-get -y install iw hostapd dnsmasq || exit 1

# The packaged hostapd service reads /etc/hostapd/hostapd.conf and would fight
# ours for the interface. Ours is a separate unit with its own config.
systemctl disable --now hostapd.service &> /dev/null || true
systemctl unmask hostapd.service &> /dev/null || true

log_progress "writing the access point configuration"
mkdir -p /etc/hostapd /etc/dnsmasq.d

# channel here is a default: teslausb-ap-up copies this to tmpfs and fills in
# whatever channel the client connection is using before hostapd starts.
cat > "$AP_CONF" <<EOF
# Written by teslausb setup. Edit teslausb_setup_variables.conf instead.
interface=ap0
driver=nl80211
ssid=${AP_SSID}
country_code=${AP_COUNTRY}
ieee80211d=1
hw_mode=g
channel=6
ignore_broadcast_ssid=0
auth_algs=1
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF
chmod 600 "$AP_CONF"

# bind-dynamic rather than bind-interfaces, because ap0 does not exist yet when
# dnsmasq starts at boot, and dnsmasq must not take over port 53 on every other
# interface either.
cat > "$AP_DNSMASQ" <<EOF
# Written by teslausb setup.
interface=ap0
bind-dynamic
dhcp-range=${AP_SUBNET}.50,${AP_SUBNET}.150,12h
dhcp-option=option:router,${AP_ADDRESS}
dhcp-option=option:dns-server,${AP_ADDRESS}
# The root filesystem is read-only in normal operation, so the leases live on the
# partition that is not.
dhcp-leasefile=/mutable/teslausb-ap.leases
EOF

cat > "$AP_UP" <<'EOF'
#!/bin/bash -eu

# Brings up ap0 and points hostapd at the right channel. Run by
# teslausb-ap.service before hostapd starts.

AP_ADDRESS="__AP_ADDRESS__"
AP_CONF="__AP_CONF__"
AP_RUNTIME_CONF="__AP_RUNTIME_CONF__"

log () { echo "teslausb-ap: $1"; }

# The client interface is whichever wifi interface is not ours. It may not exist
# yet at boot, so wait a while for it.
client=""
for _ in {1..30}
do
  client=$(iw dev | awk '/Interface/ {print $2}' | grep -v '^ap0$' | head -1)
  [ -n "$client" ] && break
  sleep 2
done

if [ -z "$client" ]
then
  log "no wifi interface found, cannot start the access point"
  exit 1
fi
log "client interface is $client"

if ! iw dev ap0 info &> /dev/null
then
  log "creating ap0 on the same radio"
  iw dev "$client" interface add ap0 type __ap
fi

# Both interfaces share the radio, so neither may sleep just because the other is
# idle.
iw dev "$client" set power_save off || true
iw dev ap0 set power_save off || true

# One radio cannot be on two channels, so the access point follows the client. If
# the client has not associated, whatever channel is already in the config stands.
freq=$(iw dev "$client" link 2> /dev/null | awk '/freq/ {print $2; exit}')
if [ -n "${freq:-}" ]
then
  if [ "$freq" -ge 5000 ]
  then
    channel=$(( (freq - 5000) / 5 ))
    band=a
  else
    channel=$(( (freq - 2407) / 5 ))
    band=g
  fi
  log "following the client onto channel $channel"
fi

# Generate the config hostapd reads. This is on tmpfs, so it works with a
# read-only root, and it is rebuilt on every start and restart.
install -m 600 "$AP_CONF" "$AP_RUNTIME_CONF"
if [ -n "${channel:-}" ]
then
  sed -i "s/^channel=.*/channel=$channel/; s/^hw_mode=.*/hw_mode=$band/" "$AP_RUNTIME_CONF"
fi

ip addr flush dev ap0 || true
ip addr add "$AP_ADDRESS/24" dev ap0
ip link set ap0 up

# Give clients of the access point a route out through the client connection, the
# way NetworkManager's shared mode used to.
sysctl -q -w net.ipv4.ip_forward=1 || true
if ! iptables -t nat -C POSTROUTING -o "$client" -j MASQUERADE &> /dev/null
then
  iptables -t nat -A POSTROUTING -o "$client" -j MASQUERADE || true
fi
EOF
sed -i "s|__AP_ADDRESS__|${AP_ADDRESS}|; s|__AP_CONF__|${AP_CONF}|; s|__AP_RUNTIME_CONF__|${AP_RUNTIME_CONF}|" "$AP_UP"
chmod 755 "$AP_UP"

cat > "$AP_UNIT" <<EOF
[Unit]
Description=teslausb access point
# wpa_supplicant owns the client connection; the access point rides on the same
# radio, so it starts after the network is being brought up.
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStartPre=${AP_UP}
ExecStart=/usr/sbin/hostapd ${AP_RUNTIME_CONF}
# The client can move to another channel, which takes the access point down with
# it. Restarting re-reads the channel and follows.
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable teslausb-ap.service
systemctl restart dnsmasq.service &> /dev/null || \
  log_progress "WARNING: dnsmasq did not restart; the access point will hand out no addresses"

log_progress "access point configured on ap0 at ${AP_ADDRESS}, ssid ${AP_SSID}"
