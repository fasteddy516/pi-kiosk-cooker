#!/bin/bash

# ensure the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
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

# set default Raspberry Pi Connect install state if it hasn't been specified
if [ ! -v rpi_connect ]; then
  rpi_connect=1
fi

# load remembered arguments from memory file (if present), then let
# command-line arguments override them by processing both in order
cli_args=("$@")
memory_file="$(dirname "$(realpath "$0")")/kiosk_cooker.memory"
if [ -f "$memory_file" ]; then
  echo "* Loading remembered arguments from $memory_file"
  # read saved args and prepend them; explicit CLI args come after and win
  saved_args=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && saved_args+=("$line")
  done < "$memory_file"
  set -- "${saved_args[@]}" "$@"
fi

# process command-line arguments
remember=0
for arg in "$@"; do
  case $arg in
    --user=*)
      app_user="${arg#*=}"
      ;;
    --password=*)
      app_password="${arg#*=}"
      ;;
    --no-reboot)
      reboot=0
      ;;
    --no-demo)
      demo=0
      ;;
    --edid=*)
      edid="${arg#*=}"
      ;;
    --displays=*)
      displays="${arg#*=}"
      if [ "$displays" != "1" ] && [ "$displays" != "2" ]; then
        echo "! Invalid value for --displays: '$displays' (must be 1 or 2)"
        exit 1
      fi
      ;;
    --no-rpi-connect)
      rpi_connect=0
      ;;
    --remember)
      remember=1
      ;;
    *)
      echo "! Unknown argument: '$arg'"
      exit 1
      ;;
  esac
done

# write remembered arguments (all args except --remember itself)
if [ $remember -eq 1 ]; then
  saved=()
  for arg in "${cli_args[@]}"; do
    [ "$arg" != "--remember" ] && saved+=("$arg")
  done
  printf '%s\n' "${saved[@]}" > "$memory_file"
  echo "* Arguments saved to $memory_file"
fi

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
apt upgrade -y
kiosk_packages="labwc wlr-randr wayland-protocols xwayland dbus-user-session seatd xterm"
if [ $rpi_connect -eq 1 ]; then
  kiosk_packages="$kiosk_packages rpi-connect"
fi
apt install -y $kiosk_packages

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

# install edid file if specified
if [ "$edid" != "none" ]; then
  mv "./${edid}.edid" /lib/firmware/${edid}.edid
fi

# Read current cmdline configuration
cmdline="$(cat /boot/firmware/cmdline.txt)"

# Remove tokens we manage (repeatable-safe)
cmdline="$(echo "$cmdline" \
  | sed -E \
    -e 's/(^| )vt\.global_cursor_default=[^ ]+//g' \
    -e 's/(^| )console=tty[0-9]+//g' \
    -e 's/(^| )video=HDMI-A-1:[^ ]+//g' \
    -e 's/(^| )video=HDMI-A-2:[^ ]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-1:[^ ]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-2:[^ ]+//g' \
    -e 's/(^| )vc4\.force_hotplug=[^ ]+//g' \
    -e 's/(^| )fsck\.repair=[^ ]+//g' \
)"

# Normalize whitespace
cmdline="$(echo "$cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

# Append our desired tokens exactly once
cmdline="$cmdline vt.global_cursor_default=0 fsck.repair=yes console=tty3"
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
  useradd -s /bin/bash -p "$(openssl passwd -6 "$app_password")" $app_user --create-home
else  
  echo "User '$app_user' already exists"
fi

# add kiosk user to required supplemental groups that exist on this OS
desired_groups="video render input seat"
available_groups=""
for group_name in $desired_groups; do
  if getent group "$group_name" > /dev/null 2>&1; then
    available_groups="${available_groups:+$available_groups,}$group_name"
  fi
done
if [ -n "$available_groups" ]; then
  usermod -aG "$available_groups" "$app_user"
fi

app_uid=$(id -u "$app_user")

# enable seatd for Wayland compositor seat management
systemctl enable seatd

# disable getty on tty1 to prevent interference with the kiosk compositor session
systemctl disable getty@tty1.service

# create compositor/session startup files
su "$app_user" -c "mkdir -p ~/.config ~/kiosk"
loginctl enable-linger "$app_user" || true
if [ $rpi_connect -eq 1 ]; then
  echo "* Enabling Raspberry Pi Connect user services"
  if [ -f /usr/lib/systemd/user/rpi-connect.service ]; then
    systemctl --global enable rpi-connect.service
  fi
  if [ -f /usr/lib/systemd/user/rpi-connect-wayvnc.service ]; then
    systemctl --global enable rpi-connect-wayvnc.service
  fi
  labwc_connect_autostart=$(cat <<'EOF'

# Keep user systemd/dbus environment aligned with this Wayland session.
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP

# Restart screen-sharing backend now that Wayland env is present.
systemctl --user restart rpi-connect-wayvnc.service >/dev/null 2>&1 || true
EOF
)
else
  echo "* Disabling Raspberry Pi Connect user services"
  systemctl --global disable rpi-connect.service >/dev/null 2>&1 || true
  systemctl --global disable rpi-connect-wayvnc.service >/dev/null 2>&1 || true
  labwc_connect_autostart=""
fi
su "$app_user" -c "mkdir -p ~/.config/labwc"
cat << EOF > /home/$app_user/.config/labwc/autostart
#!/bin/sh
$labwc_connect_autostart
EOF
chown $app_user:$app_user /home/$app_user/.config/labwc/autostart
chmod +x /home/$app_user/.config/labwc/autostart

cat << EOF > /home/$app_user/kiosk/session_start.sh
#!/bin/sh
set -eu

export XDG_RUNTIME_DIR="/run/user/$app_uid"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="labwc"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11
export SDL_VIDEODRIVER=wayland

if [ ! -d "\$XDG_RUNTIME_DIR" ] || [ ! -w "\$XDG_RUNTIME_DIR" ]; then
  echo "session_start: XDG_RUNTIME_DIR '\$XDG_RUNTIME_DIR' is missing or not writable" >&2
  exit 1
fi

exec dbus-run-session -- labwc
EOF
chown $app_user:$app_user /home/$app_user/kiosk/session_start.sh
chmod +x /home/$app_user/kiosk/session_start.sh

# create wait-for-gui-ready script to ensure the compositor is ready before starting the kiosk application
cat << EOF > /usr/local/bin/wait-for-gui-ready
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/$app_uid"
export WAYLAND_DISPLAY="wayland-0"

for _ in {1..300}; do
  [ -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ] && break
  sleep 0.1
done

for _ in {1..300}; do
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
cat <<EOF | tee /usr/local/bin/kiosk-ui-init >/dev/null
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
session_service_env=$(cat <<EOF
Environment=XDG_RUNTIME_DIR=/run/user/$app_uid
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=labwc
EOF
)
wayland_client_env=$(cat <<EOF
Environment=XDG_RUNTIME_DIR=/run/user/$app_uid
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=labwc
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
$session_service_env

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

# create systemd service to wait for the compositor session to become ready
cat << EOF > /etc/systemd/system/kiosk-session-ready.service
[Unit]
Description=Wait for kiosk $session_ready_desc session to be ready
Requires=kiosk-session.service
After=kiosk-session.service

[Service]
Type=oneshot
User=$app_user
Group=$app_user
Environment=HOME=/home/$app_user
$wayland_client_env
ExecStart=/usr/local/bin/wait-for-gui-ready
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# create systemd service to set up display layout after the session is ready
cat << EOF > /etc/systemd/system/kiosk-ui-init.service
[Unit]
Description=Initialize kiosk display layout ($ui_init_desc)
Requires=kiosk-session-ready.service
After=kiosk-session-ready.service

[Service]
Type=oneshot
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$wayland_client_env
ExecStart=/usr/local/bin/kiosk-ui-init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# create xterm demo service to run a demo application after the UI is ready (if demo mode is enabled)
cat << EOF > /etc/systemd/system/xterm-demo.service
[Unit]
Description=XTerm demo (kiosk install verification)
Requires=kiosk-ui-init.service
After=kiosk-ui-init.service

[Service]
Type=simple
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$wayland_client_env
ExecStart=/home/$app_user/kiosk/xterm_demo.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# finish setting up systemd services and targets
systemctl daemon-reload
systemctl enable kiosk-session.service
systemctl enable kiosk-session-ready.service
systemctl enable kiosk-ui-init.service
if [ $demo -eq 1 ]; then
  systemctl enable xterm-demo.service
else
  systemctl disable --now xterm-demo.service >/dev/null 2>&1 || true
fi

# create xterm demo script
su $app_user -c "touch ~/kiosk/xterm_demo.sh"
cat << EOF > /home/$app_user/kiosk/xterm_demo.sh
#!/bin/bash
set -euo pipefail

# Wait for XWayland socket (labwc starts it on first X11 client connection)
for _xi in \$(seq 1 150); do
  [ -S "/tmp/.X11-unix/X0" ] && break
  sleep 0.2
done
export DISPLAY=:0

xterm -geometry 285x65+100+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-1" & p1=\$!
if [ $displays -eq 2 ]; then
  xterm -geometry 285x65+2020+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-2" & p2=\$!
  wait "\$p1" "\$p2"
else
  wait "\$p1"
fi
EOF
su $app_user -c "chmod +x ~/kiosk/xterm_demo.sh"

# remind about rpi-connect signin if applicable
if [ $rpi_connect -eq 1 ]; then
  echo ""
  echo "*** IMPORTANT: Raspberry Pi Connect requires a one-time sign-in to link this"
  echo "    device to your Raspberry Pi ID.  Run the following command and visit the"
  echo "    URL it displays to authorize this device:"
  echo ""
  echo "    sudo -u $app_user rpi-connect signin"
  echo ""
fi

# all done - countdown to reboot
if [ $reboot -eq 1 ]; then
  echo ""
  for i in $(seq 30 -1 1) ; do echo -ne "\r*** Rebooting in $i seconds.  (CTRL-C to cancel) ***" ; sleep 1 ; done
  reboot
fi
