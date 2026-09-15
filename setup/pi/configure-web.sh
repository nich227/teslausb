#!/bin/bash -eu

setup_progress "configuring nginx"

# nginx needs somewhere writable for its logs and its cache, and the root
# filesystem is read-only in normal operation.
#
# /var/lib/nginx gets a tmpfs mount: /var/lib is on the root filesystem, so the
# mount point itself persists across reboots.
#
# /var/log/nginx is the awkward one. When this runs, DietPi's RAMlog still has a
# tmpfs on /var/log, so a directory created here lives in RAM. Later,
# make-root-fs-readonly.sh removes RAMlog and the real, empty /var/log appears,
# taking the mount point with it. The fstab entry then has nowhere to mount, which
# fails local-fs.target and drops the device into emergency mode on the next boot:
# no network, no ssh, and with no keyboard, no way in. So the mount point is created
# again after RAMlog goes, in make-root-fs-readonly.sh, and both entries carry
# nofail so that a missing mount point can never do that again.
sed -i "/.*\/nginx tmpfs.*/d" /etc/fstab
echo "tmpfs /var/log/nginx tmpfs nodev,nosuid,nofail 0 0" >> /etc/fstab
echo "tmpfs /var/lib/nginx tmpfs nodev,nosuid,nofail 0 0" >> /etc/fstab
mkdir -p /var/log/nginx
mkdir -p /var/lib/nginx
mount /var/log/nginx
mount /var/lib/nginx

# zip is needed by the web UI's own cgi-bin/downloadzip.sh, which offers any
# recording folder as a zip and is part of the interface on every install. It
# used to be installed only alongside the music/lightshow/boombox autofs mounts
# further down, so on a dashcam-only DietPi device the download button produced
# an empty file. Raspberry Pi OS Lite ships zip, which is why this was never
# noticed upstream.
apt-get -y install nginx fcgiwrap libnginx-mod-http-fancyindex fuse libfuse-dev g++ net-tools wireless-tools ethtool zip

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
fi

setup_progress "done configuring nginx"
