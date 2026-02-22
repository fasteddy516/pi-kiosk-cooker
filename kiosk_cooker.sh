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
    *)
      ;;
  esac
done

# update installed packages
apt update
apt full-upgrade -y
apt install -y xserver-xorg x11-xserver-utils xinit xinput xterm openbox unclutter x11-utils

# remove packagaes that may interfere with xorg driver selection
apt remove -y --purge xserver-xorg-video-fbdev xserver-xorg-video-all || true
apt autoremove -y

# disable splash screen (1 = disabled)
raspi-config nonint do_boot_splash 1

# disable overscan for both hdmi outputs
raspi-config nonint do_overscan_kms 1 1
raspi-config nonint do_overscan_kms 2 1

# disable screen blanking
raspi-config nonint do_blanking 1

# disable rainbow test pattern and force hdmi hotplug
sed -i -e '/disable_splash=/d' -e '/hdmi_force_hotplug=/d' -e '${/^$/d;}' /boot/firmware/config.txt
sed -i -e '$a disable_splash=1\nhdmi_force_hotplug=1\n' /boot/firmware/config.txt

# retrieve 1080P+2CH audio raw EDID file
wget "https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/edid/1080P-2CH.edid"
sudo mv ./1080P-2CH.edid /lib/firmware/1080P-2CH.edid

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
)"

# Normalize whitespace
cmdline="$(echo "$cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

# Append our desired tokens exactly once
cmdline="$cmdline loglevel=3 quiet logo.nologo plymouth.ignore-serial-consoles vt.global_cursor_default=0 \
video=HDMI-A-1:1920x1080@60D video=HDMI-A-2:1920x1080@60D \
drm.edid_firmware=HDMI-A-1:1080P-2CH.edid drm.edid_firmware=HDMI-A-2:1080P-2CH.edid \
vc4.force_hotplug=0x03"

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

# create xorg configuration to force use of modesetting driver for vc4 and set it as primary GPU
mkdir -p "/etc/X11/xorg.conf.d"
cat << 'EOF' > /etc/X11/xorg.conf.d/99-vc4.conf
Section "OutputClass"
  Identifier "vc4"
  MatchDriver "vc4"
  Driver "modesetting"
  Option "PrimaryGPU" "true"
EndSection
EOF

# disable getty on tty1 to prevent interference with Xorg
systemctl disable getty@tty1.service

# create openbox autostart script
su $app_user -c "mkdir ~/.config ; mkdir ~/.config/openbox ; touch ~/.config/openbox/autostart"
cat << EOF >> /home/$app_user/.config/openbox/autostart
# screen saver and power/sleep settings
xset -dpms     # turn off display power management system
xset s noblank # turn off screen blanking
xset s off     # turn off screen saver
EOF

# create xinitrc script to start openbox session
su "$app_user" -c "mkdir -p ~/kiosk"
cat << EOF > /home/$app_user/kiosk/xinitrc
#!/bin/sh
exec openbox-session
EOF
chown $app_user:$app_user /home/$app_user/kiosk/xinitrc
chmod +x /home/$app_user/kiosk/xinitrc

# create wait-for-x-ready script to ensure X is ready before starting the kiosk application
cat << 'EOF' > /usr/local/bin/wait-for-x-ready
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:0

# Wait for X socket
for _ in $(seq 1 300); do
  [ -S "/tmp/.X11-unix/X0" ] && break
  sleep 0.1
done

# Wait for X to respond
for _ in $(seq 1 300); do
  if xdpyinfo >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.1
done

echo "X did not become ready in time" >&2
exit 1
EOF
chmod +x /usr/local/bin/wait-for-x-ready

# create kiosk-ui-init script to set up display layout with xrandr and ensure it’s applied correctly
cat << 'EOF' > /usr/local/bin/kiosk-ui-init
#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=":0"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Tuning knobs
XRANDR_WAIT_SECS=20
APPLY_RETRIES=10
APPLY_RETRY_DELAY_SECS=0.5

# The outputs we expect
OUT1="HDMI-A-1"
OUT2="HDMI-A-2"

# Desired modes (can be overridden later if needed)
MODE1="1920x1080"
MODE2="1920x1080"

# --- Helpers ---------------------------------------------------------------

have_xrandr_outputs() {
  xrandr --query 2>/dev/null | grep -q "^${OUT1} " && \
  xrandr --query 2>/dev/null | grep -q "^${OUT2} "
}

outputs_connected() {
  xrandr --query 2>/dev/null | grep -q "^${OUT1} connected" && \
  xrandr --query 2>/dev/null | grep -q "^${OUT2} connected"
}

wait_for_outputs() {
  local deadline=$((SECONDS + XRANDR_WAIT_SECS))
  while [ $SECONDS -lt $deadline ]; do
    if have_xrandr_outputs; then
      # If nothing is physically connected, these might still show as disconnected.
      # That’s okay: with your cmdline forcing + edid_firmware, they should usually show connected.
      return 0
    fi
    sleep 0.1
  done
  return 1
}

apply_layout() {
  # Example layout: OUT1 on left, OUT2 on right
  xrandr \
    --output "${OUT1}" --mode "${MODE1}" --pos 0x0 --primary \
    --output "${OUT2}" --mode "${MODE2}" --right-of "${OUT1}"
}

layout_matches() {
  # Verify both outputs are enabled with the desired modes.
  # This is intentionally simple/robust.
  xrandr --query 2>/dev/null | awk -v o1="$OUT1" -v o2="$OUT2" '
    $1==o1 && $2=="connected" {found1=1}
    $1==o2 && $2=="connected" {found2=1}
    found1 && $0 ~ "\\b1920x1080\\b" {mode1=1}
    found2 && $0 ~ "\\b1920x1080\\b" {mode2=1}
    END { exit ! (found1 && found2 && mode1 && mode2) }
  '
}

# --- Main ------------------------------------------------------------------

# Wait for outputs to appear in xrandr
if ! wait_for_outputs; then
  echo "kiosk-ui-init: timed out waiting for ${OUT1}/${OUT2} to appear in xrandr" >&2
  xrandr --query >&2 || true
  exit 1
fi

# Apply with retries (xrandr can race early in X startup)
for _ in $(seq 1 "${APPLY_RETRIES}"); do
  if apply_layout && layout_matches; then
    exit 0
  fi
  sleep "${APPLY_RETRY_DELAY_SECS}"
done

echo "kiosk-ui-init: failed to apply/verify xrandr layout" >&2
xrandr --query >&2 || true
exit 1
EOF
chmod +x /usr/local/bin/kiosk-ui-init

# add kiosk-x.service to startx on tty1 at boot
cat << EOF > /etc/systemd/system/kiosk-x.service
[Unit]
Description=Kiosk X (startx) on tty1
After=systemd-user-sessions.service
Wants=systemd-user-sessions.service

[Service]
Type=simple
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
Environment=DISPLAY=:0

TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
PAMName=login

ExecStart=/usr/bin/startx /home/$app_user/kiosk/xinitrc -- :0 -nolisten tcp vt1
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# create systemd target to signal when X is ready for the kiosk application to start
cat << 'EOF' > /etc/systemd/system/kiosk-x-ready.target
[Unit]
Description=Kiosk X session is ready

[Install]
WantedBy=multi-user.target
EOF

# create systemd service to wait for X to be ready and then signal kiosk-x-ready.target
cat << EOF > /etc/systemd/system/kiosk-x-ready.service
[Unit]
Description=Wait for kiosk X to be ready
After=kiosk-x.service
Wants=kiosk-x.service

[Service]
Type=oneshot
User=$app_user
Group=$app_user
Environment=HOME=/home/$app_user
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/wait-for-x-ready
RemainAfterExit=yes

[Install]
WantedBy=kiosk-x-ready.target
EOF

# create systemd target to signal when the kiosk UI is fully ready (X + display layout applied) for the kiosk application to start
cat << 'EOF' > /etc/systemd/system/kiosk-ui-ready.target
[Unit]
Description=Kiosk UI is ready (X + display layout applied)

[Install]
WantedBy=multi-user.target
EOF

# create systemd service to set up display layout with xrandr after X is ready, and then signal kiosk-ui-ready.target
cat << EOF > /etc/systemd/system/kiosk-ui-init.service
[Unit]
Description=Initialize kiosk display layout (xrandr)
Requires=kiosk-x-ready.target
After=kiosk-x-ready.target

[Service]
Type=oneshot
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/kiosk-ui-init
RemainAfterExit=yes

[Install]
WantedBy=kiosk-ui-ready.target
EOF

# create xterm demo service to run a demo application after X is ready (if demo mode is enabled)
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
Environment=DISPLAY=:0
ExecStart=/home/$app_user/kiosk/xterm_demo.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# finish setting up systemd services and targets
systemctl daemon-reload
systemctl enable kiosk-x.service
systemctl enable kiosk-x-ready.target
systemctl enable kiosk-ui-ready.target
if [ $demo -eq 1 ]; then
  systemctl enable xterm-demo.service
fi

# create xterm demo script
su $app_user -c "touch ~/kiosk/xterm_demo.sh"
cat << 'EOF' > /home/$app_user/kiosk/xterm_demo.sh
#!/bin/bash
set -euo pipefail

# Optional: let the session settle a moment
sleep 2

xterm -geometry 285x65+100+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-1" &
xterm -geometry 285x65+2020+100 -xrm 'XTerm.vt100.allowTitleOps: false' -T "This is HDMI-2" &
EOF
su $app_user -c "chmod +x ~/kiosk/xterm_demo.sh"

# Create/replace rc.local script
cat << 'EOF' > /etc/rc.local
#!/bin/bash

# Check if the first-boot script exists before executing
if [ -x /usr/local/bin/first-boot.sh ]; then
  echo "* Running first-boot.sh script"
  /usr/local/bin/first-boot.sh
  echo "* first-boot.sh script completed"
else
  echo "@ first-boot.sh script not found or not executable, skipping"
fi

# Check if the app-update script exists before executing
if [ -x /usr/local/bin/app-update.sh ]; then
  echo "* Running app-update.sh script"
  /usr/local/bin/app-update.sh
  echo "* app-update.sh script completed"
else
  echo "@ app-update.sh script not found or not executable, skipping"
fi

exit 0
EOF
chmod +x /etc/rc.local

# all done - countdown to reboot
if [ $reboot -eq 1 ]; then
  echo ""
  for i in `seq 30 -1 1` ; do echo -ne "\r*** Rebooting in $i seconds.  (CTRL-C to cancel) ***" ; sleep 1 ; done
  sudo reboot
fi
