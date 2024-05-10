# Raspberry Pi Kiosk Cooker
##### A bash script to turn a Raspberry Pi into a barebones X Windows kiosk.  

_Tested on Raspberry Pi 4B and 5 hardware running Raspberry Pi OS Lite (64-bit) "Bookworm"_

This is a script I use for the initial set up of a Raspberry Pi as a single or dual-display kiosk-style device.  Typical use cases are status/dashboard displays, automated media players and touch control interfaces (for [Home Assistant](https://www.home-assistant.io/) in my case).  This script _does not_ fully set up the Pi for these cases, but  _does_ take care of the initial set up of a barebones X Windows environment such that running the necessary application(s) should be relatively straight-forward.

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

## Preparing a Kiosk Image for Cloning
### The simple way
`curl -sS "https://raw.githubusercontent.com/fasteddy516/pi-kiosk-cooker/main/prepare_for_cloning.sh" | sudo bash`

### The safer way
```
wget https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/prepare_for_cloning.sh
chmod +x prepare_for_cloning.sh
./prepare_for_cloning.sh
```

Note that the final step of the `prepare_for_cloning.sh` script is to power down the Pi.  At this point it is ready to have the MicroSD card removed and imaged.
