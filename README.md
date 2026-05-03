# Raspberry Pi Kiosk Cooker
##### A bash script to turn a Raspberry Pi into a barebones kiosk system on Raspberry Pi OS.  

_Tested on Raspberry Pi 5 hardware running Raspberry Pi OS Lite (64-bit) "Trixie"_

This is a script I use for the initial set up of a Raspberry Pi as a single or dual-display kiosk-style device.  Typical use cases are status/dashboard displays, automated media players and touch control interfaces (for [Home Assistant](https://www.home-assistant.io/) in my case).  This script _does not_ fully set up the Pi for these cases, but _does_ take care of the initial set up of a barebones kiosk environment such that running the necessary application(s) should be relatively straight-forward.

## Disclaimer
I use this script for hobby/personal projects in non-critical, controlled environments; there is virtually no thought put into securing/hardening the device or operating system.  Like the associated MIT license says, "THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND", so use it at your own risk! (But I *do* hope you find it useful, as I do!)

## Installation
### The simple way
`curl -sS "https://raw.githubusercontent.com/fasteddy516/pi-kiosk-cooker/main/kiosk_cooker.sh" | sudo bash -s -- --user=<user> --password=<pass>`

### The safer way
```
wget https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/kiosk_cooker.sh
chmod +x kiosk_cooker.sh
./kiosk_cooker.sh --user=<user> --password=<pass>
```

## Available arguments
`--user=<user>` sets the desired kiosk application user name

`--password=<password>` sets the desired password for the kiosk application user

`--no-reboot` disables the automatic reboot at the end of the script.  Useful when chaining this script into another application's install script.

`--no-demo` disables the default kiosk demo service (`xterm-demo.service`).  Again, useful when chaining into another application's install script.

`--no-rpi-connect` skips installation of Raspberry Pi Connect (`rpi-connect`).  Connect is installed and its user services enabled globally by default.

`--edid=<name>` sets the EDID profile to use for the display(s).  Defaults to `1080P-2CH`.  Use `--edid=none` to skip EDID configuration entirely.

`--displays=<1|2>` sets the number of HDMI displays to configure.  Defaults to `2`.

`--remember` saves all other arguments provided on this run to a `kiosk_cooker.memory` file next to the script.  On subsequent runs, those saved arguments are automatically prepended to the command line so you don't have to repeat them.  Explicitly provided arguments always override saved ones.  Delete `kiosk_cooker.memory` to clear the saved arguments.

> **Warning:** Any password passed via `--password` will be stored as plaintext in `kiosk_cooker.memory`.  Avoid using `--remember` together with `--password` in security-sensitive environments, or delete the memory file once the password is no longer needed.

## Raspberry Pi Connect
This script uses a Wayland/labwc kiosk session, which is compatible with full Raspberry Pi Connect screen sharing when `rpi-connect` is installed.  (Previous versions of this script used an X11/Openbox session, which does not support RPi Connect screen sharing.) 

If you pass `--rpi-connect`, the script installs full Connect (not lite) and enables `rpi-connect.service` and `rpi-connect-wayvnc.service` at the global user level.

Account linking requires a one-time sign-in after installation.  Because screen sharing runs under the kiosk application user, sign-in must be performed as that user — not as a separate admin account.  The easiest way to do this is via a Raspberry Pi Connect remote shell session:

1. After the Pi reboots, open a remote shell to the Pi and log in as the kiosk application user (the value passed to `--user`).
2. Run `rpi-connect signin` and follow the URL it prints to authorize the device with your Raspberry Pi ID.
3. Once authorized, screen sharing will be available through Raspberry Pi Connect.