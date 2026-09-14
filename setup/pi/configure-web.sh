#!/bin/bash -eu

setup_progress "configuring nginx"

# nginx needs somewhere writable for its logs and its cache, and the root
# filesystem is read-only in normal operation.
#
# /var/lib/nginx gets a tmpfs mount: /var/lib is on the root filesystem, so the
# mount point itself persists across reboots.
#
# /var/log/nginx does not. On DietPi /var/log is already a tmpfs, so anything
# inside it is gone on the next boot, including a mount point. An fstab entry for
# it therefore fails at every boot, local-fs.target fails with it, and the device
# drops into emergency mode: no network, no ssh, and with no keyboard attached, no
# way in at all. Since /var/log is already a tmpfs, a plain directory in it is
# just as good as a mount, and systemd-tmpfiles recreates it on every boot.
sed -i "/.*\/nginx tmpfs.*/d" /etc/fstab
echo "tmpfs /var/lib/nginx tmpfs nodev,nosuid 0 0" >> /etc/fstab
cat > /etc/tmpfiles.d/teslausb-nginx.conf <<'EOF'
# Written by teslausb setup. /var/log is a tmpfs, so this has to be recreated on
# every boot rather than mounted from fstab.
d /var/log/nginx 0755 root adm -
EOF
mkdir -p /var/log/nginx
mkdir -p /var/lib/nginx
mount /var/lib/nginx

apt-get -y install nginx fcgiwrap libnginx-mod-http-fancyindex fuse libfuse-dev g++ net-tools wireless-tools ethtool

# install data files and config files
systemctl stop nginx.service &> /dev/null || true
mkdir -p /var/www
umount /var/www/html/TeslaCam &> /dev/null || true
umount /var/www/html/fs/Music &> /dev/null || true
umount /var/www/html/fs/LightShow &> /dev/null || true
umount /var/www/html/fs/Boombox &> /dev/null || true
# -delete rather than piping to xargs: on a fresh DietPi the webroot is empty,
# because nginx-common there ships no default index page, and "xargs -0 rm" with
# nothing to remove exits 123 with "rm: missing operand", which killed setup here.
find /var/www/html -mount \( -type f -o -type l \) -delete
cp -r "$SOURCE_DIR/teslausb-www/html" /var/www/
ln -sf /teslausb/teslausb-headless-setup.log /var/www/html/
ln -sf /mutable/archiveloop.log /var/www/html/
ln -sf /tmp/diagnostics.txt /var/www/html/
mkdir -p /var/www/html/TeslaCam
cp -rf "$SOURCE_DIR/teslausb-www/teslausb.nginx" /etc/nginx/sites-available
ln -sf /etc/nginx/sites-available/teslausb.nginx /etc/nginx/sites-enabled/default

# Setup /etc/nginx/.htpasswd if user requested web auth, otherwise disable auth_basic
if [ -n "${WEB_USERNAME:-}" ] && [ -n "${WEB_PASSWORD:-}" ]
then
  apt-get -y install apache2-utils
  htpasswd -bc /etc/nginx/.htpasswd "$WEB_USERNAME" "$WEB_PASSWORD"
  sed -i 's/auth_basic off/auth_basic "Restricted Content"/' /etc/nginx/sites-available/teslausb.nginx
else
  sed -i 's/auth_basic "Restricted Content"/auth_basic off/' /etc/nginx/sites-available/teslausb.nginx
fi

# install the fuse layer needed to work around an incompatibility
# between Chrome and Tesla's recordings
g++ -o /root/cttseraser -D_FILE_OFFSET_BITS=64 "$SOURCE_DIR/teslausb-www/cttseraser.cpp" -lstdc++ -lfuse

# The web UI (CloudScape SPA) ships prebuilt in teslausb-www/html and is
# installed by the cp above; it is the default and only interface.


cat > /sbin/mount.ctts << EOF
#!/bin/bash -eu
/root/cttseraser "\$@" -o allow_other
EOF
chmod +x /sbin/mount.ctts

sed -i '/mount.ctts/d' /etc/fstab
echo "mount.ctts#/mutable/TeslaCam /var/www/html/TeslaCam fuse defaults,nofail,x-systemd.requires=/mutable 0 0" >> /etc/fstab
mkdir -p /mutable/TeslaCam

sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

# to get diagnostics and perform other teslausb functionality,
# nginx needs to be able to sudo
echo 'www-data ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010_www-data-nopasswd
chmod 440 /etc/sudoers.d/010_www-data-nopasswd

# allow multiple concurrent cgi calls
cat > /etc/default/fcgiwrap << EOF
DAEMON_OPTS="-c 4 -f"
EOF

if [ -e /backingfiles/music_disk.bin ] || [ -e /backingfiles/lightshow_disk.bin ] || [ -e /backingfiles/boombox_disk.bin ]
then
  mkdir -p /var/www/html/fs
  copy_script run/auto.www /root/bin
  echo "/var/www/html/fs  /root/bin/auto.www" > /etc/auto.master.d/www.autofs
  apt-get -y install zip
fi

setup_progress "done configuring nginx"
