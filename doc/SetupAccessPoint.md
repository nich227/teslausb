# Access point setup

The device can serve its own wifi network, so you can reach the web interface and
the recordings from a phone in the car, nowhere near your home network.

Set these in `teslausb_setup_variables.conf` before the first boot:

```
export AP_SSID='TESLAUSB WIFI'
export AP_PASS='at least eight characters'
export AP_IP='192.168.66.1'
```

`AP_IP` is optional and defaults to `192.168.66.1`. `AP_PASS` must be at least
eight characters, and setup refuses the literal example value `password`.

Connect to `AP_SSID` and open `http://192.168.66.1/`, or whatever you set `AP_IP`
to.

## How it works

The access point does not replace the normal wifi connection. Both run at once on
one radio, using a second virtual interface called `ap0`:

- DietPi keeps managing the client connection on `wlan0`, exactly as it would
  without an access point.
- `hostapd` serves the access point on `ap0` with WPA2 and CCMP.
- `dnsmasq` hands out addresses on `ap0` from `AP_IP`'s `/24`, in the range `.50`
  to `.150`, and points clients at the device as their router and DNS server.
- Clients are masqueraded onto the client connection, so they still have a route
  out while connected to the device.

One radio cannot be on two channels at once, so the access point follows whatever
channel the client connection is using. The service is restarted if the client
moves, which re-reads the channel.

The country code defaults to `US`. Set `WIFI_COUNTRY` in your config to change it.

## What runs on the device

| Path | What it is |
| --- | --- |
| `/etc/hostapd/teslausb-ap.conf` | the template, with your SSID and passphrase |
| `/run/teslausb-ap.conf` | what hostapd actually reads, generated at start with the current channel |
| `/etc/dnsmasq.d/teslausb-ap.conf` | DHCP for `ap0` only |
| `/usr/local/bin/teslausb-ap-up` | creates `ap0`, assigns `AP_IP`, picks the channel |
| `/mutable/teslausb-ap.leases` | DHCP leases |
| `teslausb-ap.service` | runs the above, then hostapd |

The generated config and the leases live outside the root filesystem because the
root filesystem is read-only in normal operation.

## Checking it

```
systemctl status teslausb-ap
iw dev ap0 info
journalctl -u teslausb-ap -n 50
```

If the service is restarting, `journalctl` has hostapd's reason. A wrong or
unsupported `WIFI_COUNTRY` is a common one: hostapd refuses to start on a country
code it does not accept, including the `00` placeholder some images use.

If clients associate but get no address, check `dnsmasq`:

```
systemctl status dnsmasq
cat /mutable/teslausb-ap.leases
```

## Why not NetworkManager

Earlier versions of this used NetworkManager, which Raspberry Pi OS ships and
DietPi does not. Getting an access point that way meant installing NetworkManager
during setup, migrating the wifi credentials to it, disabling DietPi's own wlan
configuration and rebooting to complete the handover. If any of that went wrong,
the device came back with neither wifi nor an access point, which is exactly when
you would want one. hostapd on `ap0` leaves the client connection alone.
