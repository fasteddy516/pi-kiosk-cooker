#!/bin/bash

# ensure the script is being run as root
if [ "$(id -u)" -eq 0 ]; then
  # check if SUDO_USER is set
  if [ -n "$SUDO_USER" ]; then
    echo "* Script is run by sudo, original user is $SUDO_USER"
    original_user=$SUDO_USER
  else
    echo "* Script is run by root, but not through sudo"
    original_user=$(whoami)
  fi
else
  echo "! This script must be run as root (i.e. with sudo)"
  exit
fi

# set default reboot state if necessary
if [ ! -v reboot ]; then
  reboot=1
fi

# set default demo state if necessary
if [ ! -v demo ]; then
  demo=1
fi

# set default application username if it hasn't been specified
if [ ! -v app_user ]; then
  app_user=pi
fi

# set default application password if it hasn't been specified
if [ ! -v app_password ]; then
  app_password=raspberry
fi

# set default edid if it hasn't been specified
if [ ! -v edid ]; then
  edid=1080P-2CH
fi

# set default number of displays if it hasn't been specified
if [ ! -v displays ]; then
  displays=2
fi

# process command-line arguments
for arg in "$@"; do
  case $arg in
    --user=*)
      app_user="${arg#*=}"
      shift
      ;;
    --password=*)
      app_password="${arg#*=}"
      shift
      ;;
    --no-reboot)
      reboot=0
      shift
      ;;
    --no-demo)
      demo=0
      shift
      ;;
    --edid=*)
      edid="${arg#*=}"
      shift
      ;;
    --displays=*)
      displays="${arg#*=}"
      if [ "$displays" != "1" ] && [ "$displays" != "2" ]; then
        echo "! Invalid value for --displays: '$displays' (must be 1 or 2)"
        exit 1
      fi
      shift
      ;;
    *)
      ;;
  esac
done

# download specified edid file (if any) before making any system changes
if [ "$edid" != "none" ]; then
  echo "* Downloading EDID file '${edid}.edid'..."
  if ! wget -q "https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/edid/${edid}.edid"; then
    echo "! Failed to download EDID file '${edid}.edid' - aborting"
    exit 1
  fi
fi

# update installed packages
apt update
apt full-upgrade -y
apt install -y labwc wlr-randr wayland-protocols xwayland dbus-user-session seatd xinput xterm x11-utils

# remove orphaned packages
apt autoremove -y

# disable splash screen (1 = disabled)
raspi-config nonint do_boot_splash 1

# disable overscan for active hdmi outputs
raspi-config nonint do_overscan_kms 1 1
if [ $displays -eq 2 ]; then
  raspi-config nonint do_overscan_kms 2 1
fi

# disable screen blanking
raspi-config nonint do_blanking 1

# disable rainbow test pattern and force hdmi hotplug
sed -i -e '/disable_splash=/d' -e '/hdmi_force_hotplug=/d' -e '${/^$/d;}' /boot/firmware/config.txt
sed -i -e '$a disable_splash=1\nhdmi_force_hotplug=1\n' /boot/firmware/config.txt

# install edid file if specified
if [ "$edid" != "none" ]; then
  mv "./${edid}.edid" /lib/firmware/${edid}.edid
fi

# Read current cmdline configuration
cmdline="$(cat /boot/firmware/cmdline.txt)"

# Remove tokens we manage (repeatable-safe)
cmdline="$(echo "$cmdline" \
  | sed -E \
    -e 's/(^| )loglevel=[^ ]+//g' \
    -e 's/(^| )quiet//g' \
    -e 's/(^| )logo\.nologo//g' \
    -e 's/(^| )plymouth\.ignore-serial-consoles//g' \
    -e 's/(^| )vt\.global_cursor_default=[^ ]+//g' \
    -e 's/(^| )video=HDMI-A-1:[^ ]+//g' \
    -e 's/(^| )video=HDMI-A-2:[^ ]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-1:[^ ]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-2:[^ ]+//g' \
    -e 's/(^| )vc4\.force_hotplug=[^ ]+//g' \
    -e 's/(^| )systemd\.show_status=[^ ]+//g' \
    -e 's/(^| )fsck\.mode=[^ ]+//g' \
    -e 's/(^| )fsck\.repair=[^ ]+//g' \
)"

# Normalize whitespace
cmdline="$(echo "$cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

# Append our desired tokens exactly once
cmdline="$cmdline loglevel=3 quiet logo.nologo plymouth.ignore-serial-consoles vt.global_cursor_default=0 \
systemd.show_status=false fsck.repair=yes"
if [ "$edid" != "none" ]; then
  if [ "$displays" -eq 2 ]; then
    cmdline="$cmdline \
video=HDMI-A-1:1920x1080@60D video=HDMI-A-2:1920x1080@60D \
drm.edid_firmware=HDMI-A-1:${edid}.edid drm.edid_firmware=HDMI-A-2:${edid}.edid \
vc4.force_hotplug=0x03"
  else
    cmdline="$cmdline \
video=HDMI-A-1:1920x1080@60D \
drm.edid_firmware=HDMI-A-1:${edid}.edid \
vc4.force_hotplug=0x01"
  fi
fi

# write the updated cmdline back to the file
echo "$cmdline" > /boot/firmware/cmdline.txt

# create default application user if necessary
grep "^$app_user:" /etc/passwd > /dev/null
if [ $? -ne 0 ]; then
  echo "User '$app_user' does not exist and will be created"
  useradd -s /bin/bash -p "$(openssl passwd -6 $app_password)" $app_user --create-home
  usermod -aG video,render $app_user
else  
  echo "User '$app_user' already exists"
fi

app_uid=$(id -u "$app_user")

# disable getty on tty1 to prevent interference with the kiosk compositor session
systemctl disable getty@tty1.service

# create compositor/session startup files
su "$app_user" -c "mkdir -p ~/.config ~/kiosk"
loginctl enable-linger "$app_user" || true
su "$app_user" -c "mkdir -p ~/.config/labwc"
cat << EOF > /home/$app_user/.config/labwc/autostart
#!/bin/sh
EOF
chown $app_user:$app_user /home/$app_user/.config/labwc/autostart
chmod +x /home/$app_user/.config/labwc/autostart

cat << EOF > /home/$app_user/kiosk/session_start.sh
#!/bin/sh
set -eu

export XDG_RUNTIME_DIR="/run/user/$app_uid"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="labwc"
export WAYLAND_DISPLAY="wayland-0"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$app_uid/bus"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11
export SDL_VIDEODRIVER=wayland

exec labwc
EOF
chown $app_user:$app_user /home/$app_user/kiosk/session_start.sh
chmod +x /home/$app_user/kiosk/session_start.sh

# create wait-for-gui-ready script to ensure the compositor is ready before starting the kiosk application
cat << EOF > /usr/local/bin/wait-for-gui-ready
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$app_uid"
export WAYLAND_DISPLAY="wayland-0"

for _ in \
$(seq 1 300); do
  [ -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ] && break
  sleep 0.1
done

for _ in \
$(seq 1 300); do
  if wlr-randr >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done

echo "Wayland did not become ready in time" >&2
exit 1
EOF
chmod +x /usr/local/bin/wait-for-gui-ready

# create kiosk-ui-init script to set up display layout after the compositor is ready
if [ "$edid" != "none" ]; then
  kiosk_force_mode=1
  kiosk_mode="1920x1080"
else
  kiosk_force_mode=0
  kiosk_mode=""
fi
kiosk_num_displays=$displays
cat <<EOF | sudo tee /usr/local/bin/kiosk-ui-init >/dev/null
#!/usr/bin/env bash
set -euo pipefail

export HOME="/home/$app_user"
export XDG_RUNTIME_DIR="/run/user/$app_uid"
export WAYLAND_DISPLAY="wayland-0"

FORCE_MODE="$kiosk_force_mode"
MODE="$kiosk_mode"
NUM_DISPLAYS="$kiosk_num_displays"

WAIT_SECS=20
APPLY_RETRIES=20
APPLY_RETRY_DELAY_SECS=0.5

log() { echo "kiosk-ui-init: \$*"; }

wait_for_socket() {
  local path="\$1" secs="\$2"
  local deadline=\$((SECONDS + secs))
  while [ \$SECONDS -lt \$deadline ]; do
    [ -S "\$path" ] && return 0
    sleep 0.1
  done
  return 1
}

wayland_query() {
  wlr-randr 2>/dev/null
}

pick_outputs() {
  local outs
  outs="\$(wayland_query | awk '/^HDMI-A-[0-9]+ /{print \$1} /^HDMI-[0-9]+ /{print \$1}' | head -n "\$NUM_DISPLAYS")"
  echo "\$outs"
}

main() {
  log "Waiting for Wayland socket..."
  if ! wait_for_socket "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" "\$WAIT_SECS"; then
    log "Timed out waiting for \$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY"
    exit 1
  fi

  local deadline=\$((SECONDS + WAIT_SECS))
  while [ \$SECONDS -lt \$deadline ]; do
    if wayland_query >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  local outs out1 out2
  outs="\$(pick_outputs)"
  out1="\$(echo "\$outs" | sed -n '1p')"
  out2="\$(echo "\$outs" | sed -n '2p')"

  if [ -z "\${out1:-}" ]; then
    log "Could not find primary HDMI output via wlr-randr. Full output state:"
    wayland_query || true
    exit 1
  fi

  if [ "\$NUM_DISPLAYS" -eq 2 ] && [ -z "\${out2:-}" ]; then
    log "Could not find second HDMI output via wlr-randr. Full output state:"
    wayland_query || true
    exit 1
  fi

  for _ in \$(seq 1 "\$APPLY_RETRIES"); do
    if [ "\$FORCE_MODE" -eq 1 ]; then
      if [ "\$NUM_DISPLAYS" -eq 2 ]; then
        if wlr-randr --output "\$out1" --on --mode "\$MODE" --pos 0,0 \
          && wlr-randr --output "\$out2" --on --mode "\$MODE" --pos 1920,0; then
          log "Layout applied successfully."
          exit 0
        fi
      else
        if wlr-randr --output "\$out1" --on --mode "\$MODE" --pos 0,0; then
          log "Layout applied successfully."
          exit 0
        fi
      fi
    else
      if [ "\$NUM_DISPLAYS" -eq 2 ]; then
        if wlr-randr --output "\$out1" --on --pos 0,0 \
          && wlr-randr --output "\$out2" --on; then
          log "Layout applied successfully."
          exit 0
        fi
      else
        if wlr-randr --output "\$out1" --on --pos 0,0; then
          log "Layout applied successfully."
          exit 0
        fi
      fi
    fi

    sleep "\$APPLY_RETRY_DELAY_SECS"
  done

  log "Failed to apply layout after retries. Current output state:"
  wayland_query || true
  exit 1
}

main "\$@"
EOF
chmod +x /usr/local/bin/kiosk-ui-init
session_env=$(cat <<EOF
Environment=XDG_RUNTIME_DIR=/run/user/$app_uid
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=labwc
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus
EOF
)
session_exec="ExecStart=/home/$app_user/kiosk/session_start.sh"
session_ready_desc="Wayland"
ui_init_desc="wlr-randr"

# add kiosk-session.service to start the graphical session on tty1 at boot
cat << EOF > /etc/systemd/system/kiosk-session.service
[Unit]
Description=Kiosk graphical session on tty1
After=systemd-user-sessions.service systemd-logind.service
Wants=systemd-user-sessions.service

[Service]
Type=simple
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$session_env

TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
PAMName=login

$session_exec
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# create systemd target to signal when the graphical session is ready for the kiosk application to start
cat << 'EOF' > /etc/systemd/system/kiosk-session-ready.target
[Unit]
Description=Kiosk graphical session is ready

[Install]
WantedBy=multi-user.target
EOF

# create systemd service to wait for the compositor to be ready and then signal kiosk-session-ready.target
cat << EOF > /etc/systemd/system/kiosk-session-ready.service
[Unit]
Description=Wait for kiosk $session_ready_desc session to be ready
After=kiosk-session.service
Wants=kiosk-session.service

[Service]
Type=oneshot
User=$app_user
Group=$app_user
Environment=HOME=/home/$app_user
$session_env
ExecStart=/usr/local/bin/wait-for-gui-ready
RemainAfterExit=yes

[Install]
WantedBy=kiosk-session-ready.target
EOF

# create systemd target to signal when the kiosk UI is fully ready for the kiosk application to start
cat << 'EOF' > /etc/systemd/system/kiosk-ui-ready.target
[Unit]
Description=Kiosk UI is ready

[Install]
WantedBy=multi-user.target
EOF

# create systemd service to set up display layout after the graphical session is ready
cat << EOF > /etc/systemd/system/kiosk-ui-init.service
[Unit]
Description=Initialize kiosk display layout ($ui_init_desc)
Requires=kiosk-session-ready.target
After=kiosk-session-ready.target

[Service]
Type=oneshot
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$session_env
ExecStart=/usr/local/bin/kiosk-ui-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# create xterm demo service to run a demo application after the UI is ready (if demo mode is enabled)
cat << EOF > /etc/systemd/system/xterm-demo.service
[Unit]
Description=XTerm demo (kiosk install verification)
Requires=kiosk-ui-ready.target
After=kiosk-ui-ready.target

[Service]
Type=simple
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$session_env
Environment=DISPLAY=:0
ExecStart=/home/$app_user/kiosk/xterm_demo.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# finish setting up systemd services and targets
systemctl daemon-reload
systemctl enable kiosk-session.service
systemctl enable kiosk-ui-ready.target
systemctl enable kiosk-ui-init.service
systemctl enable kiosk-session-ready.target
if [ $demo -eq 1 ]; then
  systemctl enable xterm-demo.service
fi

# create xterm demo script
su $app_user -c "touch ~/kiosk/xterm_demo.sh"
cat << EOF > /home/$app_user/kiosk/xterm_demo.sh
#!/bin/bash
set -euo pipefail

# Optional: let the session settle a moment
sleep 2

xterm -geometry 285x65+100+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-1" & p1=\$!
if [ $displays -eq 2 ]; then
  xterm -geometry 285x65+2020+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-2" & p2=\$!
  wait "\$p1" "\$p2"
else
  wait "\$p1"
fi
EOF
su $app_user -c "chmod +x ~/kiosk/xterm_demo.sh"

# all done - countdown to reboot
if [ $reboot -eq 1 ]; then
  echo ""
  for i in `seq 30 -1 1` ; do echo -ne "\r*** Rebooting in $i seconds.  (CTRL-C to cancel) ***" ; sleep 1 ; done
  sudo reboot
fi
