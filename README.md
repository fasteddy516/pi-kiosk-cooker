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

## What this script does

The following is a breakdown of every significant action the script performs, and why.

### Package installation
The script sets `DEBIAN_FRONTEND=noninteractive` for the duration of its execution so that `apt` and `dpkg` never block on interactive prompts (e.g. config file conflict dialogs during `apt upgrade`). It then runs `apt update` and `apt upgrade` to bring the system fully up to date, then installs the packages required for a Wayland kiosk session:

| Package | Purpose |
|---|---|
| `labwc` | A lightweight Wayland compositor (window manager) used as the kiosk session. |
| `wlr-randr` | Command-line tool to query and configure Wayland outputs (used by `kiosk-ui-init`). |
| `wayland-protocols` | Wayland extension protocols required by labwc and Wayland clients. |
| `xwayland` | Compatibility layer so X11 applications can run inside the Wayland session. |
| `dbus-user-session` | Provides a per-user D-Bus session bus, required by Wayland and labwc. |
| `seatd` | A seat management daemon that grants unprivileged users access to input and display hardware without requiring root. |
| `xterm` | A minimal terminal emulator, used by the optional demo service to verify the kiosk environment is working. |
| `rpi-connect` _(optional)_ | Full Raspberry Pi Connect package (not lite), required for screen sharing support. Installed by default; skipped when `--no-rpi-connect` is passed. |

### Boot configuration (`/boot/firmware/cmdline.txt`)
The kernel command line is modified idempotently — existing tokens managed by this script are removed before the desired set is appended, so re-running the script never duplicates entries.

| Token | Purpose |
|---|---|
| `vt.global_cursor_default=0` | Hides the blinking text cursor on Linux virtual terminals (the console), so it doesn't show through the compositor before the graphical session starts. |
| `fsck.repair=yes` | Automatically repairs filesystem errors on boot instead of dropping to a recovery prompt, keeping the kiosk unattended-safe. |
| `console=tty3` | Redirects kernel console output to tty3 (a background virtual terminal), so boot messages don't appear on the primary display. |
| `video=HDMI-A-1:1920x1080@60D` _(optional)_ | Forces the first HDMI output to 1920×1080 @ 60 Hz at the kernel/DRM level before any display manager is involved. Only added when an EDID profile is in use. |
| `video=HDMI-A-2:1920x1080@60D` _(optional)_ | Same as above for the second HDMI output. Only added when an EDID profile is in use and `--displays=2`. |
| `drm.edid_firmware=HDMI-A-1:<name>.edid` _(optional)_ | Overrides the EDID reported by the display on HDMI-1 with a firmware-supplied file. This is necessary when a connected display doesn't expose a valid EDID (e.g. a long HDMI run, a splitter, or a capture card), which would otherwise cause the output to be disabled or configured incorrectly. |
| `drm.edid_firmware=HDMI-A-2:<name>.edid` _(optional)_ | Same as above for HDMI-2. |
| `vc4.force_hotplug=0x01` / `0x03` _(optional)_ | Forces the VC4 GPU driver to treat the specified HDMI output(s) as always-connected, even when no display is detected. Without this, outputs with overridden EDID may still be disabled if the HPD (hot-plug detect) pin reads as disconnected. `0x01` enables it for HDMI-1; `0x03` for both. |

### `raspi-config` settings
Three display-related settings are applied via `raspi-config`'s non-interactive interface:

- **Splash screen disabled** — The Raspberry Pi firmware splash screen is turned off so boot proceeds cleanly to the kiosk compositor.
- **Overscan/underscan disabled** (both HDMI outputs) — Disables the legacy overscan compensation that adds black borders around the image, which is unnecessary on modern displays.
- **Screen blanking disabled** — Prevents the display from going blank after a period of inactivity, which is undesirable for a kiosk.

### Kiosk application user
A dedicated user account (default: `pi`) is created for running the kiosk session and all associated applications. Running as a non-root user limits the blast radius of any application-level issue and is required by `seatd` and the Wayland session model. The user is added to the `video`, `render`, `input`, and `seat` groups so it can access the GPU, input devices, and seat management without elevated privileges.

`loginctl enable-linger` is called for this user so that user-level systemd services (including D-Bus) start at boot without requiring an interactive login session.

### Wayland session setup
The kiosk session is built around three layered systemd services:

**`kiosk-session.service`** starts the Wayland compositor (`labwc`) directly on tty1, running as the kiosk user. By running `labwc` through `session_start.sh` (which wraps it in `dbus-run-session`), the compositor gets its own D-Bus session bus and the correct Wayland/XDG environment variables. Getty on tty1 is disabled so it doesn't conflict with the compositor claiming that terminal.

**`kiosk-session-ready.service`** runs `wait-for-gui-ready`, a script that polls for the Wayland socket (`$XDG_RUNTIME_DIR/wayland-0`) and then confirms the compositor is responsive via `wlr-randr`. This gate prevents dependent services from trying to interact with the compositor before it is actually ready.

**`kiosk-ui-init.service`** runs `kiosk-ui-init` after the session is confirmed ready. This script uses `wlr-randr` to enumerate connected HDMI outputs and apply the desired display layout — enabling the correct outputs, setting resolution and position. When an EDID profile is in use the resolution is forced explicitly; otherwise the compositor's negotiated mode is accepted. Applying layout from a separate script (rather than a labwc config file) gives fine-grained control and retries, which is important on hardware where outputs may not be immediately enumerable right as the compositor starts.

**`labwc/autostart`** is a shell script that labwc executes at session start. When Raspberry Pi Connect is enabled, it imports the Wayland session environment into systemd and D-Bus so that `rpi-connect-wayvnc.service` can reach the compositor for screen sharing.

### Demo service (`xterm-demo.service`)
An optional demo application runs after the display layout is initialised. It opens one `xterm` window per configured display to confirm that the Wayland session is running, displays appear correctly, and XWayland (for X11 application compatibility) is functional. This service is enabled by default and can be disabled with `--no-demo` (or removed once you replace it with your own application service).

---

## Raspberry Pi Connect
This script uses a Wayland/labwc kiosk session, which is compatible with full Raspberry Pi Connect screen sharing when `rpi-connect` is installed.  (Previous versions of this script used an X11/Openbox session, which does not support RPi Connect screen sharing.) 

By default, the script installs full Connect (not lite) and enables `rpi-connect.service` and `rpi-connect-wayvnc.service` at the global user level. Pass `--no-rpi-connect` to skip installation entirely.

Account linking requires a one-time sign-in after installation.  Because screen sharing runs under the kiosk application user, sign-in must be performed as that user — not as a separate admin account.  The easiest way to do this is via a Raspberry Pi Connect remote shell session:

1. After the Pi reboots, open a remote shell to the Pi and log in as the kiosk application user (the value passed to `--user`).
2. Run `rpi-connect signin` and follow the URL it prints to authorize the device with your Raspberry Pi ID.
3. Once authorized, screen sharing will be available through Raspberry Pi Connect.