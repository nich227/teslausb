#!/bin/bash -eu

# Builds the lab's NAS disk from the official Debian genericcloud image.
#
# The NAS used to be a second DietPi, which meant sitting through DietPi's first
# run twice: roughly ten minutes of apt upgrade and first-run bookkeeping for a
# box whose only job is to serve a share and answer mDNS. A cloud image has no
# first run at all. It boots into cloud-init, which applies the whole
# configuration in one pass, so the NAS is ready in about a minute.
#
# Debian rather than Alpine, deliberately. Alpine boots faster still, but it is
# built on musl, and musl has no NSS plugin support, so libnss-mdns cannot work
# there. Part of the lab's job is asserting that an ordinary client on the network
# resolves teslausb.local by name; on Alpine that would have to be downgraded to
# calling avahi-resolve by hand, which stops testing the thing that matters.
# Debian keeps glibc, and with it the resolution path a real NAS uses.
#
# Nothing belonging to teslausb runs here. This image is plumbing, not a subject.
#
# Usage: prepare-nas-image.sh <output.qcow2>
#
# Environment:
#   NAS_IP        address on the private lab segment (default 10.99.0.20)
#   NAS_HOSTNAME  hostname and mDNS name (default teslanas)
#   MAC_NAT       MAC of the NIC that reaches the internet, configured by DHCP
#   MAC_PRIVATE   MAC of the NIC on the private segment, configured statically
#   SHARE_NAME    share name and directory under /srv (default teslacam)
#   SHARE_USER    account that owns the share (default teslausb)
#   SHARE_PASS    its password, for SMB and for the account
#   ARCHIVE       cifs or rsync: decides which server is set up
#   SSH_PUBKEY    public key installed for root
#   VM_PASSWORD   root password, for console access
#   CACHE_DIR     where the base image is kept
#   APT_PROXY     optional proxy for apt, e.g. http://10.0.2.2:3142

OUT="${1:?usage: prepare-nas-image.sh <output.qcow2>}"

: "${NAS_IP:=10.99.0.20}"
: "${NAS_HOSTNAME:=teslanas}"
: "${MAC_NAT:=}"
: "${MAC_PRIVATE:=}"
: "${SHARE_NAME:=teslacam}"
: "${SHARE_USER:=teslausb}"
: "${SHARE_PASS:=archivepass}"
: "${ARCHIVE:=cifs}"
: "${SSH_PUBKEY:=}"
: "${VM_PASSWORD:=teslausb-lab}"
: "${CACHE_DIR:=/KevNAS/Projects/teslausb-cache}"
: "${APT_PROXY:=}"

readonly BASE_IMAGE_NAME="debian-12-genericcloud-amd64.qcow2"
readonly BASE_URL="https://cloud.debian.org/images/cloud/bookworm/latest"

log () { printf '    [nas-image] %s\n' "$1"; }

case "$ARCHIVE" in
  cifs|rsync) ;;
  *) echo "FATAL: ARCHIVE must be cifs or rsync, got '$ARCHIVE'" >&2; exit 1 ;;
esac

mkdir -p "$CACHE_DIR"
base="$CACHE_DIR/$BASE_IMAGE_NAME"

# ---------------------------------------------------------------------------
# The base image, cached, and refreshed when Debian publishes a new one.
#
# This is the "latest" image, so its published checksum changes every time Debian
# rebuilds it, roughly monthly. A cached copy from before a rebuild is not corrupt,
# it is superseded, and the right response is to fetch the new one rather than
# refuse to run: a lab that had passed for days failed on every variant the morning
# Debian rotated the image, with nothing in this repository having changed. A
# download that then still fails the checksum is a real problem and is fatal.
# ---------------------------------------------------------------------------
fetch_base () {
  log "fetching $BASE_IMAGE_NAME"
  curl -fsSL --retry 3 -o "$base.part" "$BASE_URL/$BASE_IMAGE_NAME"
  mv "$base.part" "$base"
}

published_sha512 () {
  curl -fsSL --retry 3 -o "$CACHE_DIR/SHA512SUMS" "$BASE_URL/SHA512SUMS"
  awk -v n="$BASE_IMAGE_NAME" '$2 == n {print $1}' "$CACHE_DIR/SHA512SUMS"
}

[ -s "$base" ] || fetch_base

log "verifying sha512"
expected=$(published_sha512)
if [ -z "$expected" ]
then
  log "WARNING: no published checksum for $BASE_IMAGE_NAME, continuing"
elif [ "$expected" != "$(sha512sum "$base" | awk '{print $1}')" ]
then
  log "cached $BASE_IMAGE_NAME no longer matches the published checksum: Debian has"
  log "released a new image, fetching it"
  rm -f "$base"
  fetch_base
  if [ "$expected" != "$(sha512sum "$base" | awk '{print $1}')" ]
  then
    echo "FATAL: freshly downloaded $base does not match the published sha512" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# cloud-init seed. Everything the NAS needs is declared here and applied on its
# only boot: addresses, the account, the share, and mDNS.
# ---------------------------------------------------------------------------
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT

if [ "$ARCHIVE" = cifs ]
then
  packages="samba avahi-daemon libnss-mdns openssh-server curl rsync"
else
  # teslausb's rsync backend is rsync over ssh, so the NAS needs a real account
  # and an absolute destination path rather than an rsync daemon module.
  packages="rsync avahi-daemon libnss-mdns openssh-server curl"
fi

{
  echo "#cloud-config"
  echo "hostname: $NAS_HOSTNAME"
  echo "fqdn: $NAS_HOSTNAME.local"
  echo "preserve_hostname: false"
  echo "disable_root: false"
  echo "ssh_pwauth: true"
  echo
  echo "chpasswd:"
  echo "  expire: false"
  echo "  list: |"
  echo "    root:$VM_PASSWORD"
  echo
  echo "users:"
  echo "  - name: root"
  echo "    lock_passwd: false"
  if [ -n "$SSH_PUBKEY" ]
  then
    echo "    ssh_authorized_keys:"
    echo "      - $SSH_PUBKEY"
  fi
  echo "  - name: $SHARE_USER"
  echo "    lock_passwd: false"
  echo "    shell: /bin/bash"
  echo "    plain_text_passwd: $SHARE_PASS"
  echo
  if [ -n "$APT_PROXY" ]
  then
    echo "apt:"
    echo "  proxy: $APT_PROXY"
    echo
  fi
  echo "package_update: true"
  echo "packages:"
  for p in $packages
  do
    echo "  - $p"
  done
  echo
  echo "write_files:"
  echo "  - path: /etc/avahi/avahi-daemon.conf"
  echo "    content: |"
  echo "      [server]"
  echo "      host-name=$NAS_HOSTNAME"
  echo "      use-ipv4=yes"
  echo "      use-ipv6=no"
  echo "      [publish]"
  echo "      publish-addresses=yes"
  echo "      publish-hinfo=no"
  echo "      publish-workstation=no"
  echo
  echo "runcmd:"
  # The share directory exists before anything exports it. An earlier version of
  # the lab had the device try to mount the share half a minute before samba was
  # installed, and teslausb setup gave up on the archive for good.
  echo "  - mkdir -p /srv/$SHARE_NAME"
  echo "  - chown $SHARE_USER:$SHARE_USER /srv/$SHARE_NAME"
  echo "  - chmod 775 /srv/$SHARE_NAME"
  if [ "$ARCHIVE" = cifs ]
  then
    printf '  - printf %s >> /etc/samba/smb.conf\n' \
      "'[$SHARE_NAME]\\n   path = /srv/$SHARE_NAME\\n   read only = no\\n   guest ok = no\\n   valid users = $SHARE_USER\\n   force user = $SHARE_USER\\n'"
    echo "  - bash -c \"(echo '$SHARE_PASS'; echo '$SHARE_PASS') | smbpasswd -s -a $SHARE_USER\""
    echo "  - systemctl enable --now smbd"
  fi
  echo "  - sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
  echo "  - systemctl restart ssh"
  echo "  - systemctl enable --now avahi-daemon"
  # A marker the lab can wait on, so it never pokes a half configured NAS.
  echo "  - touch /run/nas-ready"
} > "$seed_dir/user-data"

cat > "$seed_dir/meta-data" <<META
instance-id: teslausb-lab-nas
local-hostname: $NAS_HOSTNAME
META

# Interfaces are matched by MAC rather than by name: the predictable names depend
# on the machine type and PCI layout, and getting them wrong here means either no
# internet or no private segment.
{
  echo "version: 2"
  echo "ethernets:"
  if [ -n "$MAC_NAT" ]
  then
    echo "  nat:"
    echo "    match:"
    echo "      macaddress: $MAC_NAT"
    echo "    dhcp4: true"
  fi
  if [ -n "$MAC_PRIVATE" ]
  then
    echo "  private:"
    echo "    match:"
    echo "      macaddress: $MAC_PRIVATE"
    echo "    dhcp4: false"
    echo "    addresses:"
    echo "      - $NAS_IP/24"
  fi
} > "$seed_dir/network-config"

log "building the cloud-init seed"
seed_out="${OUT%.qcow2}-seed.iso"
xorriso -as mkisofs -quiet -output "$seed_out" \
  -volid CIDATA -joliet -rock \
  "$seed_dir/user-data" "$seed_dir/meta-data" "$seed_dir/network-config" 2> /dev/null

# ---------------------------------------------------------------------------
# Overlay, so the base image is never written to and a run can be thrown away.
# ---------------------------------------------------------------------------
rm -f "$OUT"
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$OUT" 8G
log "image ready: $(basename "$OUT") with seed $(basename "$seed_out")"
