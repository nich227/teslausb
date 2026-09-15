#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "verify-and-configure-archive: $*"
    return
  fi
  echo "verify-and-configure-archive: $1"
}

function install_required_packages () {
  # rclone is in neither the DietPi nor the Raspberry Pi OS base image, and no
  # other part of setup installs it, so a device configured for the rclone
  # backend reaches verify_configuration with no rclone at all. The `rclone lsd`
  # below then fails with "command not found" and reports the misleading
  # "Could not find the $RCLONE_DRIVE:$RCLONE_PATH" instead of the real cause.
  #
  # Only installed when missing, so a newer rclone installed by hand from
  # rclone.org (which is what rclone's own documentation recommends) is left
  # alone rather than being shadowed by the distribution package.
  if command -v rclone > /dev/null
  then
    return
  fi
  log_progress "rclone is not installed, installing it"
  apt-get -y install rclone
}

install_required_packages

function verify_configuration () {
    log_progress "Verifying rclone configuration..."
    if ! [ -e "/root/.config/rclone/rclone.conf" ]
    then
        log_progress "STOP: rclone config was not found. did you configure rclone correctly?"
        exit 1
    fi

    if ! rclone lsd "$RCLONE_DRIVE:$RCLONE_PATH" > /dev/null
    then
        log_progress "STOP: Could not find the $RCLONE_DRIVE:$RCLONE_PATH"
        exit 1
    fi
}

verify_configuration

function configure_archive () {
  log_progress "Configuring rclone archive..."

  # Ensure that /root/.config/rclone is a directory not a symlink
  if [ ! -L "/root/.config/rclone" ] && [ -d "/root/.config/rclone" ]
  then
    log_progress "Moving rclone configs into /mutable"
    # make sure that /mutable is mounted prior to moving rclone configuration
    if ! findmnt --mountpoint /mutable
    then
      mount /mutable
    fi
    # Creating only configs dir so we can move the rclone dir into it
    mkdir -p /mutable/configs
    # Moving the directory itself to ensure the link creation works correctly
    mv /root/.config/rclone /mutable/configs/
    # Creating link, this requires the directory /root/.config/rclone to be nonexistent
    ln -s /mutable/configs/rclone /root/.config/rclone
  fi

  log_progress "Done"
}

configure_archive
