#!/bin/bash -eu

# Print the URLs the web interface is actually reachable on.
#
# The name to use is not always the system hostname. avahi publishes
# <host-name>.local, and teslausb sets host-name in avahi-daemon.conf when
# TESLAUSB_MDNS_NAME asks for something different from the machine name, so a
# device whose hostname is Kevster-TeslaUSB can answer only to teslausb.local.
# Printing the hostname there sends people to a name that does not resolve:
# Kevster-TeslaUSB.local returns nothing on such a device, while teslausb.local
# answers immediately.
#
# The bare hostname is never printed either. Without a suffix it depends on the
# resolver's search domain or on NetBIOS, neither of which is in play here; the
# .local form is what mDNS actually answers.
#
# Called from the login tip, so it runs at login rather than being baked in when
# setup ran, and follows a changed address or name.

readonly AVAHI_CONF="${AVAHI_CONF:-/etc/avahi/avahi-daemon.conf}"

function mdns_name () {
  local name=""
  if [ -r "$AVAHI_CONF" ]
  then
    # Only an uncommented host-name= counts; the packaged config ships it
    # commented out, which means avahi falls back to the system hostname.
    name=$(sed -n 's/^host-name=[[:blank:]]*\([^[:blank:]#]*\).*/\1/p' "$AVAHI_CONF" | tail -1)
  fi
  if [ -z "$name" ]
  then
    name=$(hostname -s 2> /dev/null || hostname)
  fi
  printf '%s.local' "$name"
}

function first_address () {
  # hostname -I lists every address; the first IPv4 one is the useful one. An
  # address on the access point interface is not, since a client reading this over
  # ssh is on the other network.
  local addr
  for addr in $(hostname -I 2> /dev/null)
  do
    case "$addr" in
      *:*) continue ;;          # IPv6
      169.254.*) continue ;;    # link-local, no use to anyone
      192.168.66.*) continue ;; # the access point's own subnet
      *) printf '%s' "$addr"; return 0 ;;
    esac
  done
  return 1
}

name=$(mdns_name)
if addr=$(first_address)
then
  printf 'http://%s or http://%s\n' "$name" "$addr"
else
  printf 'http://%s\n' "$name"
fi
