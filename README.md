# Raspberry Pi Kiosk Cooker
##### A bash script to turn a Raspberry Pi into a barebones kiosk system on Raspberry Pi OS.  

_Tested on Raspberry Pi 5 hardware running Raspberry Pi OS Lite (64-bit) "Trixie"_

Written by [Edward Wright](mailto:fasteddy@thewrightspace.net) (fasteddy516).

Available at https://github.com/fasteddy516/pi-kiosk-cooker


## Description
This is a script I use for the initial set up of a Raspberry Pi as a single or dual-display kiosk-style device.  Typical use cases are status/dashboard displays, automated media players and touch control interfaces (for [Home Assistant](https://www.home-assistant.io/) in my case).  This script _does not_ fully set up the Pi for these cases, but _does_ take care of the initial set up of a barebones kiosk environment such that running the necessary application(s) should be relatively straight-forward.

> [!WARNING]
> I use this script for hobby/personal projects in non-critical, controlled environments; there is virtually no thought put into securing/hardening the device or operating system.  In recent versions I have made heavy use of GitHub Copilot to assist with script additions and improvements.  Like the associated MIT license says, "THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND", so use it at your own risk! (But I *do* hope you find it useful, as I do!)


## Installation
### The simple way:
`curl -sS "https://raw.githubusercontent.com/fasteddy516/pi-kiosk-cooker/main/kiosk_cooker.sh" | sudo bash -s -- --password=<pass>`

### The safer way:
```
wget https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/kiosk_cooker.sh
chmod +x kiosk_cooker.sh
./kiosk_cooker.sh --password=<pass>
```

## Available arguments
`--user=<user>` sets the desired kiosk application user name.  Defaults to `kiosk`.

`--password=<password>` sets the desired password for the kiosk application user.  Required argument (no default).

`--displays=<1|2>` sets the number of HDMI displays to configure.  Defaults to `1`.

`--video=<value>` adds a `video=<value>` token to `/boot/firmware/cmdline.txt`.  This argument may be specified multiple times.  Values are passed through without parsing or validation, so use the exact kernel video argument value you want, for example `--video=HDMI-A-1:1280x800@60D`.  When at least one `--video` argument is specified, all existing `video=` tokens are removed from `cmdline.txt` before the specified ones are added; when no `--video` argument is specified, existing `video=` tokens are left untouched.

`--edid=<name>` sets the EDID profile to use for the display(s).  Defaults to `none` (skip EDID configuration).

> [!NOTE]
> At this time, the only supported EDID options are `none` (the default) and `1080P-2CH` (1080p@60Hz with 2-channel PCM audio).  

`--no-touch-keyboard` disables installation and setup of the on-screen touch keyboard (`squeekboard`).

`--no-rpi-connect` skips installation of Raspberry Pi Connect (`rpi-connect`).  Connect is installed and its user services enabled globally by default.

`--no-default-application` disables the generated default Chromium kiosk browser user services (`kioskbrowser-1.service` and `kioskbrowser-2.service`).  When omitted, the default browser application services are enabled according to the configured display count.

`--no-reboot` disables the automatic reboot at the end of the script.

`--remember` saves all other arguments provided on this run to a `kiosk_cooker.memory` file next to the script.  On subsequent runs, those saved arguments are automatically prepended to the command line so you don't have to repeat them.  Explicitly provided arguments always override saved ones.  Delete `kiosk_cooker.memory` to clear the saved arguments.

> [!WARNING]
> Any password passed via `--password` will be stored as **plaintext** in `kiosk_cooker.memory`.  Avoid using `--remember` together with `--password` in security-sensitive environments, or delete the memory file once the password is no longer needed.


## Window Positioning
This kiosk environment uses compositor rules (labwc `WindowRules` inside `~/.config/labwc/rc.xml`) to control application window placement as follows:

1) Any application with an identifier (`app_id`) *or* window title that contains `HDMI-A-1` will be automatically moved to that output/display.

2) Any application with an identifier *or* window title that contains `HDMI-A-2` will be automatically moved to that output/display.

3) Any application with an identifier *or* window title that contains `Maximized` will be maximized on whatever display it is displayed on.

The full screen browser demo applications included in this script have identifiers that contain `HDMI-A-1-Maximized` and `HDMI-A-2-Maximized` to ensure they get routed to the correct output and take up all of the available screen real estate.  


## Under the hood

The following is a breakdown of every significant action the script performs, and why.

### Package installation
The script sets `DEBIAN_FRONTEND=noninteractive` for the duration of its execution so that `apt` and `dpkg` never block on interactive prompts (e.g. config file conflict dialogs during `apt upgrade`). It then runs `apt update` and `apt upgrade` to bring the system fully up to date, then installs the packages required for a Wayland kiosk session:

| Package | Purpose |
|---|---|
| `labwc` | A lightweight Wayland compositor (window manager) used as the kiosk session. |
| `wlr-randr` | Command-line tool to query and configure Wayland outputs (used by the kiosk session launcher). |
| `wlopm` | Command-line tool to control Wayland output power management, useful for display blanking/power-state control. |
| `wayland-protocols` | Wayland extension protocols required by labwc and Wayland clients. |
| `xwayland` | Compatibility layer so X11 applications can run inside the Wayland session. |
| `dbus-user-session` | Provides a per-user D-Bus session bus, required by Wayland and labwc. |
| `seatd` | A seat management daemon that grants unprivileged users access to input and display hardware without requiring root. |
| `chromium-browser` / `chromium` | Chromium-based browser used for fullscreen kiosk operation. The script installs whichever package is available on the target OS. |
| `squeekboard` _(when available and not disabled)_ | Wayland on-screen keyboard. Installed and managed as a dedicated user-level systemd service (`touchkeyboard.service`) so it can be enabled/disabled independently of the compositor and browser services. |
| `rpi-connect` _(optional)_ | Full Raspberry Pi Connect package (not lite), required for screen sharing support. Installed by default; skipped when `--no-rpi-connect` is passed. |

### Boot configuration (`/boot/firmware/cmdline.txt`)
The kernel command line is modified idempotently — existing tokens managed by this script are removed before the desired set is appended, so re-running the script never duplicates entries. As part of this cleanup, any existing `quiet` and `console=tty<n>` tokens are removed. Existing `video=` tokens are only removed when one or more `--video` arguments are specified; otherwise they are preserved.

| Token | Purpose |
|---|---|
| `vt.global_cursor_default=0` | Hides the blinking text cursor on Linux virtual terminals (the console), so it doesn't show through the compositor before the graphical session starts. |
| `fsck.repair=yes` | Automatically repairs filesystem errors on boot instead of dropping to a recovery prompt, keeping the kiosk unattended-safe. |
| `logo.nologo` | Suppresses Linux kernel framebuffer logos during early boot (including Raspberry Pi kernel logos), reducing boot-time branding artifacts on-screen. |
| `systemd.getty_auto=no` | Disables systemd's automatic getty generation from the kernel command line, reducing chances of VT login prompts briefly reappearing during shutdown/reboot transitions. |
| `video=<value>` _(optional, repeatable)_ | Adds caller-supplied kernel/DRM video settings before any display manager is involved. Added only when one or more `--video=<value>` arguments are specified. Values are not parsed or validated by this script. |
| `drm.edid_firmware=HDMI-A-1:<name>.edid` _(optional)_ | Overrides the EDID reported by the display on HDMI-1 with a firmware-supplied file. This is necessary when a connected display doesn't expose a valid EDID (e.g. a long HDMI run, a splitter, or a capture card), which would otherwise cause the output to be disabled or configured incorrectly. |
| `drm.edid_firmware=HDMI-A-2:<name>.edid` _(optional)_ | Same as above for HDMI-2. |
| `vc4.force_hotplug=0x01` / `0x03` _(optional)_ | Forces the VC4 GPU driver to treat the specified HDMI output(s) as always-connected, even when no display is detected. Without this, outputs with overridden EDID may still be disabled if the HPD (hot-plug detect) pin reads as disconnected. `0x01` enables it for HDMI-1; `0x03` for both. |

### `raspi-config` settings
Three display-related settings are applied via `raspi-config`'s non-interactive interface:

- **Plymouth splash disabled** — The standard Plymouth splash is disabled.
- **Overscan/underscan disabled** (both HDMI outputs) — Disables the legacy overscan compensation that adds black borders around the image, which is unnecessary on modern displays.
- **Screen blanking disabled** — Prevents the display from going blank after a period of inactivity, which is undesirable for a kiosk.

In addition, the script directly enforces `disable_splash=1` in `/boot/firmware/config.txt` to disable the early firmware Raspberry logo splash reliably across Raspberry Pi OS variants.

### Kiosk application user
A dedicated user account (default: `kiosk`) is created for running the kiosk session and all associated applications. Running as a non-root user limits the blast radius of any application-level issue and is required by `seatd` and the Wayland session model. The user is added to the `video`, `render`, `input`, and `seat` groups so it can access the GPU, input devices, and seat management without elevated privileges.

`loginctl enable-linger` is called for this user so that user-level systemd services (including D-Bus) start at boot without requiring an interactive login session.

### Wayland session setup
The kiosk session is built around one system-level systemd service plus a user-level `kiosk.target` for the default browser application services:

**`kiosk.service`** starts `/home/<app_user>/.local/bin/kiosk` directly on tty1, running as the kiosk user. That launcher exports the Wayland/XDG/input-method environment, starts `labwc` through `dbus-run-session`, and keeps the compositor as the foreground process so systemd tracks the graphical session lifetime. Getty on tty1 is fully disabled (`disable --now`) and masked so a console login prompt does not return and cannot conflict with the compositor claiming that terminal. To harden this further, the script also sets `NAutoVTs=0` and `ReserveVT=0` in `/etc/systemd/logind.conf` to stop automatic virtual-console getty spawning.

At compositor startup, labwc is configured to run the `HideCursor` action on first window map so the pointer disappears automatically without waiting for an initial touch event.

The launcher also starts a background initialization task before it execs `labwc`. That task waits for the Wayland socket (`$XDG_RUNTIME_DIR/wayland-0`), confirms the compositor is responsive via `wlr-randr`, then enumerates connected HDMI outputs and applies the desired display layout — enabling the correct outputs, setting resolution and position. When an EDID profile is in use the resolution is forced explicitly; otherwise the compositor's negotiated mode is accepted. Once layout is applied successfully, the launcher imports the live Wayland environment into the kiosk user's systemd manager and starts `kiosk.target`, which in turn starts the enabled kiosk user services.

**`kiosk.target`** is installed in `/home/<app_user>/.config/systemd/user/kiosk.target` and acts as the user-level grouping point for kiosk application services, including the default browser services and optional touch keyboard. It is started by the session launcher after the display layout is ready.

**`labwc/autostart`** is a shell script that labwc executes at session start. When Raspberry Pi Connect is enabled, it imports the Wayland session environment into systemd and D-Bus so that `rpi-connect-wayvnc.service` can reach the compositor for screen sharing.

**`touchkeyboard.service`** is an optional user-level systemd service installed at `/home/<app_user>/.config/systemd/user/touchkeyboard.service` when `squeekboard` is available and `--no-touch-keyboard` is not used. It starts `squeekboard` under `kiosk.target` with the same Wayland environment as the browser services, and can be toggled independently:

- Disable now and on boot: `systemctl --user disable --now touchkeyboard.service`
- Enable now and on boot: `systemctl --user enable --now touchkeyboard.service`

**`labwc/rc.xml`** is generated with three layers of compositor decoration suppression. `<core><decoration>client</decoration>` instructs labwc to prefer client-side decorations (CSD) globally, meaning windows negotiate their own frame via the `xdg-decoration` protocol rather than having the compositor draw a title bar. Chromium, when launched with `WaylandWindowDecorations` in `--enable-features`, requests CSD and suppresses its own title bar when maximized. A `<windowRule identifier="*" serverDecoration="no"/>` rule acts as a belt-and-suspenders fallback in case CSD negotiation fails for any window. Finally, a custom zero-pixel `kiosk` theme (`border.width: 0`, `titlebar.height: 0`) is installed under `~/.local/share/themes/kiosk/openbox-3/themerc` and referenced via `<theme><name>kiosk</name></theme>` — if server-side decorations are ever applied despite the above, they render invisibly.

### Browser kiosk service (`kioskbrowser-1.service`)
After the graphical session and display layout are ready, `kioskbrowser-1.service` starts a fullscreen Chromium kiosk instance for display 1 and is configured with `Restart=always` so it automatically respawns if it exits or crashes. This is a user-level systemd service installed at `/home/<app_user>/.config/systemd/user/kioskbrowser-1.service` and enabled under `kiosk.target`.

The service runs `/home/<app_user>/applications/kioskbrowser-1/start.sh`, which launches Chromium in app mode (`--app`) with startup prompts and browser chrome disabled. App mode is used instead of `--kiosk`/`--start-fullscreen` because Chromium's true kiosk mode uses exclusive Wayland fullscreen, which prevents compositor layer-shell surfaces (such as `squeekboard`) from rendering above the browser window — meaning the on-screen keyboard would always appear behind it. The launcher uses display/maximize hints in the Chromium profile name so labwc window rules can move the window to `HDMI-A-1` and maximize it without claiming exclusive fullscreen. It also enables Wayland IME support (`--enable-wayland-ime`), enables Chromium virtual keyboard and CSD features (`--enable-features=...,VirtualKeyboard,WaylandWindowDecorations`, `--enable-virtual-keyboard`), and forces touch input mode (`--touch-events=enabled`). `WaylandWindowDecorations` is critical: it causes Chromium to negotiate client-side decorations with labwc via the `xdg-decoration` protocol, and when maximized Chromium suppresses its own title bar — keeping the window borderless without relying on compositor-drawn decorations.

Initial startup content is a local static page at `/home/<app_user>/applications/kioskbrowser-1/index.html`.

That page includes a URL field and **Set start page** button. Enter a URL, tap the button, and Chromium will prompt once to choose a folder. Select `/home/<app_user>/applications/kioskbrowser-1/settings`; the page then writes `startup_url.txt` in that folder and immediately navigates to the entered URL.

You can still set the URL manually by creating `/home/<app_user>/applications/kioskbrowser-1/settings/startup_url.txt` with a single line containing the URL (for example `https://example.com`).

When present and valid (`http://`, `https://`, or `file://`), that value is used. If the file is missing or invalid, the launcher falls back to the local startup page.

### Display 2 service (`kioskbrowser-2.service`)
The script also creates a parallel display 2 browser setup:

- `/home/<app_user>/applications/kioskbrowser-2/index.html`
- `/home/<app_user>/applications/kioskbrowser-2/start.sh`
- `/home/<app_user>/.config/systemd/user/kioskbrowser-2.service`

When the script runs with `--displays=2`, `kioskbrowser-2.service` is enabled automatically. For single-display installs (`--displays=1`), it is left disabled. Display 2 now uses the same startup page behavior as display 1, including the in-page URL field and **Set start page** flow that writes to `/home/<app_user>/applications/kioskbrowser-2/settings/startup_url.txt`. The display 2 launcher targets `HDMI-A-2` when present.

---

## Raspberry Pi Connect
This script uses a Wayland/labwc kiosk session, which is compatible with full Raspberry Pi Connect screen sharing when `rpi-connect` is installed.  (Previous versions of this script used an X11/Openbox session, which does not support RPi Connect screen sharing.) 

By default, the script installs full Connect (not lite) and enables `rpi-connect.service` and `rpi-connect-wayvnc.service` at the global user level. Pass `--no-rpi-connect` to skip installation entirely.

Account linking requires a one-time sign-in after installation.  Because screen sharing runs under the kiosk application user, sign-in must be performed as that user — not as a separate admin account.  The easiest way to do this is via a Raspberry Pi Connect remote shell session:

1. After the Pi reboots, open a remote shell to the Pi and log in as the kiosk application user (the value passed to `--user`).
2. Run `rpi-connect signin` and follow the URL it prints to authorize the device with your Raspberry Pi ID.
3. Once authorized, screen sharing will be available through Raspberry Pi Connect.

If you are signed in as a different admin account and cannot log in directly as the kiosk user, use the kiosk user's systemd bus explicitly:

```
sudo systemctl start user@$(id -u <app_user>).service
sudo -u <app_user> XDG_RUNTIME_DIR=/run/user/$(id -u <app_user>) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u <app_user>)/bus rpi-connect signin
```

This avoids the `Failed to connect to user scope bus` error that can happen with a plain `sudo -u <app_user> rpi-connect signin`.
