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

## Raspberry Pi Connect
This script now uses a Wayland/labwc kiosk session by default so it is compatible with full Raspberry Pi Connect screen sharing when `rpi-connect` is installed.

The script does not install or enable `rpi-connect` automatically.  This keeps kiosk setup and account linking separate while ensuring the session framework is already compatible.