# One-step setup

This is a streamlined process for setting up the device. You'll flash an official DietPi image, fill out a config file, and let the device configure itself on first boot.

teslausb runs on [DietPi](https://dietpi.com/). Raspberry Pi OS is not supported.

## Notes

- Assumes your Pi has access to Wifi, with internet access (during setup). (But all setup methods do currently.) USB networking is still enabled for troubleshooting or manual setup
- This image will work for either _headless_ (tested) or _manual_ (tested less) setup.
- Currently not tested with the rclone method when using headless setup, however you can specify 'none' as the archive method in the config file, which will configure the pi as a wifi-accessible USB drive, so you can then [configure rclone](./SetupRClone.md) or [configure rsync](./SetupRSync.md) and rerun the setup-teslausb script.

## Configure the SD card before first boot of the Pi

1.  Download the DietPi image for your board from [dietpi.com/#download](https://dietpi.com/#download) and flash it with [Raspberry Pi Imager](https://www.raspberrypi.com/software/), balenaEtcher, or a similar tool.

    Do not use Raspberry Pi Imager's customisation options (hostname, wifi, SSH). DietPi has its own settings for those and teslausb fills them in for you in the next step.

1.  Mount the card again and create a `teslausb_setup_variables.conf` file with the environment variables you want (archive info, wifi, push notifications if desired).
    A sample conf file with documentation and suggested values is [in the repo](https://github.com/nich227/teslausb/blob/main-dev/dietpi/teslausb_setup_variables.conf.sample).

1.  Point the repo's helper at the boot partition. This is what makes the rest of the setup unattended: it copies your config and the teslausb bootstrap onto the card, and fills in DietPi's own pre-boot settings (unattended first boot, hostname, and your wifi credentials) so the device comes up on the network by itself.

    ```
    git clone https://github.com/nich227/teslausb
    sudo teslausb/tools/prepare-boot-partition.sh /path/to/boot/partition /path/to/teslausb_setup_variables.conf
    ```

    If you would rather do it by hand, set `AUTO_SETUP_AUTOMATED=1` and `AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1` in `dietpi.txt`, put your wifi credentials in `dietpi-wifi.txt`, and copy `dietpi/Automation_Custom_Script.sh` and your `teslausb_setup_variables.conf` to the boot partition yourself. See `dietpi/dietpi.txt.sample` for the full list.

    > **Note** DietPi brings up the network and updates itself before any teslausb code runs, which is why the wifi credentials have to be in DietPi's files as well as yours. The helper does that for you. Wifi is not optional: the device lives in your car with no ethernet, so without working credentials it will never get online and DietPi cannot finish its own first boot.

1.  Eject the card and boot the device. DietPi runs its own setup unattended (no prompts, because the helper sets `AUTO_SETUP_AUTOMATED=1`), then runs the teslausb bootstrap, which takes over and reboots as needed.

    Log in as `root` or `dietpi`. **DietPi has no `pi` user**, so this differs from the Raspberry Pi OS builds where you logged in as `pi` with the password `raspberry`. The password is whatever you set as `OS_PASSWORD` in your config, or DietPi's default of `dietpi` if you left it unset.

    > **Note** When creating/editing the configuration file on Windows, ensure that it is saved with the correct extension. It is recommended to disable the "hide extensions for known file types" option in Windows so you can see the full file name.

    Be sure that all values, especially your WiFi SSID and password are properly quoted and/or escaped according to [bash quoting rules](https://www.gnu.org/software/bash/manual/bash.html#Quoting), and that in addition any `&`, `/` and `\` are also escaped by prefixing them with a `\`.
    If the password does not contain a single quote character, you can enclose the entire password in single quotes, like so:

    ```
    export WIFIPASS='password'
    ```

    even if it contains other characters that might otherwise be special to bash, like \\, \* and $ (but note that the \\ should still be escaped with an additional \\ in order for the password to be correctly handled)

    If the password does contain a single quote, you will need to use a different syntax. E.g. if the password is `pass'word`, you would use:

    ```
    export WIFIPASS=$'pass\'word'
    ```

    and if the password contains both a single quote and a backslash, e.g. `pass'wo\rd`you'd use:

    ```
    export WIFIPASS=$'pass\'wo\\rd'
    ```

    Similarly if your WiFi SSID has spaces in its name, make sure they're escaped or quoted.

    For example, if your SSID were

    ```
    Foo Bar 2.4 GHz
    ```

    you would use

    ```
    export SSID=Foo\ Bar\ 2.4\ GHz
    ```

    or

    ```
    export SSID='Foo Bar 2.4 GHz'
    ```

1.  Boot it in your Pi, give it a few minutes, watching for a series of flashes (2, 3, 4, 5) and then a reboot and/or the CAM/music drives to become available on your PC/Mac. If you configured automatic music syncing, the drives won't be available on the PC/Mac until music syncing is complete. The LED flash stages during setup are:

    | Stage (number of flashes) | Activity                                                           |
    | ------------------------- | ------------------------------------------------------------------ |
    | 2                         | Verify the requested configuration is creatable                    |
    | 3                         | Grab scripts to start/continue setup                               |
    | 4                         | Create partition and files to store camera clips/music)            |
    | 5                         | Setup completed; remounting filesystems as read-only and rebooting |

The Pi should be available for `ssh` at `pi@teslausb.local`, over Wifi (if automatic setup works) or USB networking (if it doesn't). It takes about 5 minutes, or more depending on network speed, etc. The default password for user `pi@teslausb.local` is `raspberry`.

If plugged into just a power source, or your car, give it a few minutes until the LED starts pulsing steadily which means the archive loop is running and you're good to go.

You should see in `/teslausb` the `TESLAUSB_SETUP_FINISHED` and `WIFI_ENABLED` files as markers of headless setup success as well.

## Security

Given that the Pi contains sensitive information like your home wifi password and possible a Tesla account access token, please consider the following:

1. If WiFi Access Point is configured, ensure it is configured with a strong password. Make it something better than Passw0rd, more than 8 characters. The longer the password the better. See [here](https://en.wikipedia.org/wiki/Password_strength) or [here](https://xkcd.com/936/) for password strength.

2. Change the password for the pi account to something other than the default "raspberry". To do that, ssh into the Pi, run the following commands, and enter a new password when prompted:

```
   sudo -i
   /root/bin/remountfs_rw
   passwd pi
   reboot
```

3. Remember that the Pi contains a configuration file with sensitive information. If your Pi is stolen or you suspect an unauthorized person accessed it, immediately change your Tesla account password (if you configured the Pi to use your Tesla credentials to keep the car awake during archiving) and home wifi password.

### Troubleshooting

- If everything seems to be working, but you still don't see the USB drive(s) either on your local machine, or in the car, check that you are indeed using a USB data cable, and not a charge-only cable. Also ensure you are plugged into the USB port on the Raspberry PI, and not the power port.
- `ssh` to `pi@teslausb.local` (assuming Wifi came up, or your Pi is connected to your computer via USB) and look at the `/teslausb/teslausb-headless-setup.log`.
- Try `sudo -i` and then run `/root/bin/first-boot.sh`. The scripts are fairly resilient to restarting and not re-running previous steps, and will tell you about progress/failure. `journalctl -u teslausb-setup` shows what happened on the previous boots.
- If Wifi didn't come up:
  - Double-check the SSID and WIFIPASS variables in `teslausb_setup_variables.conf`, and remove `WIFI_ENABLED`, then boot the SD in your Pi to retry automatic Wifi setup.
  - Networking is DietPi's job. Check it with `dietpi-config` (Network Options: Adapters), and check `/boot/dietpi-wifi.txt` holds the right credentials.
  - If still no go, re-run `/root/bin/first-boot.sh`
- Note: if you get an error about `read-only filesystem`, you may have to `sudo -i` and run `/root/bin/remountfs_rw`.
- Try `date` to ensure the system clock is set correctly. If it is too far off, SSL/TLS Authentication will fail, preventing the installation from completing. You can set the date like `date -s "2 JAN 2022 15:04:05"`
- Try `tail -f /teslausb/teslausb-headless-setup.log` to watch the logs during installation, which may shed some light on any errors occurring. Press `Ctrl-C` to stop watching logs.

More troubleshooting information in the [wiki](https://github.com/marcone/teslausb/wiki/Troubleshooting)

# Background information

## What happens under the covers

When the Pi boots the first time:

- A `/teslausb/teslausb-headless-setup.log` file will be created and stages logged.
- Marker files will be created in `teslausb` like `TESLA_USB_SETUP_STARTED` and `TESLA_USB_SETUP_FINISHED` to track progress.
- Wifi is detected by looking for `/teslausb/WIFI_ENABLED`; if it is absent and `SSID`/`WIFIPASS` are set in `teslausb_setup_variables.conf`, the credentials are handed to DietPi's own wifi configuration and the device reboots. teslausb does not write `wpa_supplicant.conf` itself, because that fights DietPi for the adapter.
- The Pi LED will flash patterns (2, 3, 4, 5) as it gets to each stage (labeled in the setup-teslausb script).
- After the final stage and reboot the LED will go back to normal. Remember, the step to remount the filesystem takes a few minutes.

At this point the next boot should start the Dashcam/music drives like normal. If you're watching the LED it will start flashing every 1 second, which is the archive loop running.

> **Note** Don't delete the `TESLAUSB_SETUP_FINISHED` or `WIFI_ENABLED` files. This is how the system knows setup is complete.

# Image modification sources

There is no custom image any more: teslausb configures an official DietPi image on first boot. The pieces that do it are in the [dietpi folder](https://github.com/nich227/teslausb/tree/main-dev/dietpi).
