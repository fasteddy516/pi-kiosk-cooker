#!/bin/bash

# kiosk_cooker version (used by script and generated UI text)
SCRIPT_VERSION="1.1.0"

supports_color=0
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
  supports_color=1
fi

if [ "$supports_color" -eq 1 ]; then
  C_GREEN='\033[32m'
  C_RED='\033[31m'
  C_BRIGHT_RED='\033[91m'
  C_YELLOW='\033[93m'
  C_WHITE='\033[37m'
  C_BRIGHT_WHITE='\033[97m'
  C_LIGHT_BLUE='\033[94m'
  C_RESET='\033[0m'
else
  C_GREEN=''
  C_RED=''
  C_BRIGHT_RED=''
  C_YELLOW=''
  C_WHITE=''
  C_BRIGHT_WHITE=''
  C_LIGHT_BLUE=''
  C_RESET=''
fi

CHECKMARK="${C_GREEN}✓${C_RESET}"
CROSSMARK="${C_RED}x${C_RESET}"
OK_TEXT="${C_GREEN}OK${C_RESET}"
ERROR_TEXT="${C_RED}ERROR${C_RESET}"
CURRENT_STEP=""
LAST_COMMAND=""
LAST_EXIT_CODE=0
COMMAND_STDOUT_LOG=""
COMMAND_STDERR_LOG=""

print_line() {
  printf '%b\n' "$1"
}

init_command_logs() {
  COMMAND_STDOUT_LOG="$(mktemp /tmp/pi-kiosk-cooker-stdout.XXXXXX)" || return 1
  COMMAND_STDERR_LOG="$(mktemp /tmp/pi-kiosk-cooker-stderr.XXXXXX)" || return 1
}

cleanup_command_logs() {
  [ -n "$COMMAND_STDOUT_LOG" ] && [ -f "$COMMAND_STDOUT_LOG" ] && rm -f "$COMMAND_STDOUT_LOG"
  [ -n "$COMMAND_STDERR_LOG" ] && [ -f "$COMMAND_STDERR_LOG" ] && rm -f "$COMMAND_STDERR_LOG"
}

run_quiet() {
  LAST_COMMAND="$*"
  LAST_EXIT_CODE=0
  : > "$COMMAND_STDOUT_LOG"
  : > "$COMMAND_STDERR_LOG"
  "$@" >"$COMMAND_STDOUT_LOG" 2>"$COMMAND_STDERR_LOG"
  LAST_EXIT_CODE=$?
  return $LAST_EXIT_CODE
}

print_log_preview() {
  local label="$1"
  local file="$2"
  local max_lines=8
  local count=0

  if [ ! -s "$file" ]; then
    return
  fi

  print_line "    ! ${label}:"
  while IFS= read -r line && [ "$count" -lt "$max_lines" ]; do
    printf '      %s\n' "$line"
    count=$((count + 1))
  done < "$file"
}

print_last_command_hint() {
  local stderr_has_data=0
  local stdout_has_data=0

  if [ -n "$LAST_COMMAND" ]; then
    print_line "    ! command: $LAST_COMMAND"
  fi
  print_line "    ! exit code: $LAST_EXIT_CODE"
  if [ -n "$COMMAND_STDOUT_LOG" ] || [ -n "$COMMAND_STDERR_LOG" ]; then
    print_line "    ! logs: stdout=$COMMAND_STDOUT_LOG stderr=$COMMAND_STDERR_LOG"
  fi

  if [ -s "$COMMAND_STDERR_LOG" ]; then
    stderr_has_data=1
  fi
  if [ -s "$COMMAND_STDOUT_LOG" ]; then
    stdout_has_data=1
  fi

  print_log_preview "stderr" "$COMMAND_STDERR_LOG"
  if [ "$stderr_has_data" -eq 0 ]; then
    print_log_preview "stdout" "$COMMAND_STDOUT_LOG"
  fi

  if [ "$stderr_has_data" -eq 0 ] && [ "$stdout_has_data" -eq 0 ]; then
    print_line "    ! no stdout/stderr was captured for this command"
    case "$LAST_COMMAND" in
      raspi-config*)
        print_line "    ! hint: raspi-config can fail silently in non-interactive mode on non-Raspberry Pi OS images or when required boot files/settings are unavailable"
        ;;
    esac
  fi
}

fail() {
  print_line "! $1"
  exit 1
}

step_begin() {
  CURRENT_STEP="$1"
  LAST_COMMAND=""
  printf '[ ] %s' "$CURRENT_STEP"
}

step_ok() {
  printf '\r[%b] %s %b\n' "$CHECKMARK" "$CURRENT_STEP" "$OK_TEXT"
  CURRENT_STEP=""
}

step_error() {
  local message="${1:-}"
  printf '\r[%b] %s %b\n' "$CROSSMARK" "$CURRENT_STEP" "$ERROR_TEXT"
  if [ -n "$message" ]; then
    print_line "    ! $message"
  fi
  print_last_command_hint
  exit 1
}

step_error_continue() {
  local message="${1:-}"
  printf '\r[%b] %s %b\n' "$CROSSMARK" "$CURRENT_STEP" "$ERROR_TEXT"
  if [ -n "$message" ]; then
    print_line "    ! $message"
  fi
  print_last_command_hint
  CURRENT_STEP=""
}

run_step() {
  local text="$1"
  shift

  step_begin "$text"
  if run_quiet "$@"; then
    step_ok
  else
    step_error
  fi
}

run_step_allow_nonzero() {
  local text="$1"
  shift

  step_begin "$text"
  if run_quiet "$@"; then
    step_ok
  else
    step_ok
    print_line "    ${C_YELLOW}! note: ignored non-zero exit code $LAST_EXIT_CODE from: $LAST_COMMAND${C_RESET}"
  fi
}

run_user_systemctl() {
  local text="$1"
  shift

  run_step "$text" su "$app_user" -c "XDG_RUNTIME_DIR=/run/user/$app_uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus systemctl --user $*"
}

run_user_systemctl_allow_nonzero() {
  local text="$1"
  shift

  run_step_allow_nonzero "$text" su "$app_user" -c "XDG_RUNTIME_DIR=/run/user/$app_uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus systemctl --user $*"
}

print_line "${C_RED}🔥${C_RESET}${C_LIGHT_BLUE} pi-kiosk-cooker ${SCRIPT_VERSION} by fasteddy516${C_RESET}"

# ensure the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
  fail "This script must be run as root (i.e. with sudo)"
fi

if ! init_command_logs; then
  fail "Unable to create temporary command log files under /tmp"
fi

# suppress interactive prompts from apt/dpkg for the duration of this script
export DEBIAN_FRONTEND=noninteractive

# set default application username if it hasn't been specified
if [ ! -v app_user ]; then
  app_user=kiosk
fi

# application password has no default and must be provided via --password

# set default number of displays if it hasn't been specified
if [ ! -v displays ]; then
  displays=1
fi

# set default video kernel command-line entries if they haven't been specified
if [ ! -v video ]; then
  video=()
fi

# set default edid if it hasn't been specified
if [ ! -v edid ]; then
  edid=none
fi

# set default touch keyboard state if it hasn't been specified
if [ ! -v touch_keyboard ]; then
  touch_keyboard=1
fi

# set default Raspberry Pi Connect install state if it hasn't been specified
if [ ! -v rpi_connect ]; then
  rpi_connect=1
fi

# set default application service state if it hasn't been specified
if [ ! -v default_application ]; then
  default_application=1
fi

# set default reboot state if necessary
if [ ! -v reboot ]; then
  reboot=1
fi

# load remembered arguments from memory file (if present), then let
# command-line arguments override them by processing both in order
cli_args=("$@")
memory_file="$(dirname "$(realpath "$0")")/kiosk_cooker.memory"
if [ -f "$memory_file" ]; then
  step_begin "Loading remembered arguments from $memory_file"
  # read saved args and prepend them; explicit CLI args come after and win
  saved_args=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && saved_args+=("$line")
  done < "$memory_file"
  set -- "${saved_args[@]}" "$@"
  step_ok
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
    --displays=*)
      displays="${arg#*=}"
      if [ "$displays" != "1" ] && [ "$displays" != "2" ]; then
        fail "Invalid value for --displays: '$displays' (must be 1 or 2)"
      fi
      ;;
    --video=*)
      video+=("${arg#*=}")
      ;;
    --edid=*)
      edid="${arg#*=}"
      ;;
    --no-touch-keyboard)
      touch_keyboard=0
      ;;
    --no-rpi-connect)
      rpi_connect=0
      ;;
    --no-default-application)
      default_application=0
      ;;
    --no-reboot)
      reboot=0
      ;;
    --remember)
      remember=1
      ;;
    *)
      fail "Unknown argument: '$arg'"
      ;;
  esac
done

# require a non-empty password to be explicitly provided
if [ -z "${app_password:-}" ]; then
  fail "Missing required argument: --password=<password>"
fi

# write remembered arguments (all args except --remember itself)
if [ $remember -eq 1 ]; then
  step_begin "Saving remembered arguments to $memory_file"
  saved=()
  for arg in "${cli_args[@]}"; do
    [ "$arg" != "--remember" ] && saved+=("$arg")
  done
  if printf '%s\n' "${saved[@]}" > "$memory_file"; then
    step_ok
  else
    step_error "Unable to write remembered arguments"
  fi
fi

# download specified edid file (if any) before making any system changes
if [ "$edid" != "none" ]; then
  step_begin "Downloading EDID file '${edid}.edid'"
  if run_quiet wget -q "https://github.com/fasteddy516/pi-kiosk-cooker/raw/main/edid/${edid}.edid"; then
    step_ok
  else
    step_error "Failed to download EDID file '${edid}.edid'"
  fi
fi

# update installed packages
run_step "Updating apt package lists (this may take a few minutes)" apt update
run_step "Upgrading installed packages (this may take a few minutes)" apt upgrade -y

step_begin "Selecting Chromium package"
browser_package=""
for candidate in chromium-browser chromium; do
  candidate_version="$(apt-cache policy "$candidate" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [ -n "$candidate_version" ] && [ "$candidate_version" != "(none)" ]; then
    browser_package="$candidate"
    break
  fi
done
if [ -z "$browser_package" ]; then
  step_error "Unable to find a supported Chromium package (tried: chromium-browser, chromium)"
fi
step_ok

if [ $touch_keyboard -eq 1 ]; then
  step_begin "Checking touch keyboard package availability"
  squeekboard_version="$(apt-cache policy squeekboard 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [ -n "$squeekboard_version" ] && [ "$squeekboard_version" != "(none)" ]; then
    touch_keyboard_package="squeekboard"
    step_ok
  else
    touch_keyboard_package=""
    step_error_continue "squeekboard not found in apt repos - touch keyboard will not be available"
  fi
else
  touch_keyboard_package=""
  step_begin "Touch keyboard disabled via --no-touch-keyboard"
  step_ok
fi

kiosk_packages="labwc wlr-randr wlopm wayland-protocols xwayland dbus-user-session seatd $browser_package"
if [ -n "$touch_keyboard_package" ]; then
  kiosk_packages="$kiosk_packages $touch_keyboard_package"
fi
if [ $rpi_connect -eq 1 ]; then
  kiosk_packages="$kiosk_packages rpi-connect"
fi
run_step "Installing required packages (this may take a few minutes)" apt install -y $kiosk_packages

# remove orphaned packages
run_step "Removing orphaned packages (this may take a few minutes)" apt autoremove -y

# disable splash screen (1 = disabled)
run_step_allow_nonzero "Disabling boot splash" raspi-config nonint do_boot_splash 1

# Ensure firmware splash logos are disabled as well. On some images,
# raspi-config alone may not reliably set this in config.txt.
step_begin "Ensuring firmware splash logos are disabled"
if grep -Eq '^[[:space:]]*#?[[:space:]]*disable_splash=' /boot/firmware/config.txt; then
  if run_quiet sed -E -i 's/^[[:space:]]*#?[[:space:]]*disable_splash=.*/disable_splash=1/' /boot/firmware/config.txt; then
    step_ok
  else
    step_error "Unable to update disable_splash in /boot/firmware/config.txt"
  fi
else
  if run_quiet sh -c "printf '\n# Added by pi-kiosk-cooker to hide firmware boot logos\ndisable_splash=1\n' >> /boot/firmware/config.txt"; then
    step_ok
  else
    step_error "Unable to append disable_splash to /boot/firmware/config.txt"
  fi
fi

# disable overscan for active hdmi outputs
run_step_allow_nonzero "Disabling overscan on HDMI-A-1" raspi-config nonint do_overscan_kms 1 1
if [ $displays -eq 2 ]; then
  run_step_allow_nonzero "Disabling overscan on HDMI-A-2" raspi-config nonint do_overscan_kms 2 1
fi

# disable screen blanking
run_step_allow_nonzero "Disabling screen blanking" raspi-config nonint do_blanking 1

# install edid file if specified
if [ "$edid" != "none" ]; then
  run_step "Installing EDID firmware file" mv "./${edid}.edid" /lib/firmware/${edid}.edid
fi

# Read current cmdline configuration
cmdline="$(cat /boot/firmware/cmdline.txt)"

# Remove tokens we manage (repeatable-safe)
cmdline="$(echo "$cmdline" \
  | sed -E \
    -e 's/(^| )quiet( |$)/ /g' \
    -e 's/(^| )logo\.nologo( |$)/ /g' \
    -e 's/(^| )systemd\.getty_auto=[^ ]+//g' \
    -e 's/(^| )vt\.global_cursor_default=[^ ]+//g' \
    -e 's/(^| )console=tty[0-9]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-1:[^ ]+//g' \
    -e 's/(^| )drm\.edid_firmware=HDMI-A-2:[^ ]+//g' \
    -e 's/(^| )vc4\.force_hotplug=[^ ]+//g' \
    -e 's/(^| )fsck\.repair=[^ ]+//g' \
)"

# Remove existing video= tokens only when replacement video entries were specified.
if [ "${#video[@]}" -gt 0 ]; then
  filtered_cmdline=""
  for cmdline_token in $cmdline; do
    case "$cmdline_token" in
      video=*)
        ;;
      *)
        filtered_cmdline="${filtered_cmdline:+$filtered_cmdline }$cmdline_token"
        ;;
    esac
  done
  cmdline="$filtered_cmdline"
fi

# Normalize whitespace
cmdline="$(echo "$cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

# Append our desired tokens exactly once
cmdline="$cmdline vt.global_cursor_default=0 fsck.repair=yes logo.nologo systemd.getty_auto=no"
if [ "${#video[@]}" -gt 0 ]; then
  for video_entry in "${video[@]}"; do
    cmdline="$cmdline video=$video_entry"
  done
fi
if [ "$edid" != "none" ]; then
  if [ "$displays" -eq 2 ]; then
    cmdline="$cmdline \
drm.edid_firmware=HDMI-A-1:${edid}.edid drm.edid_firmware=HDMI-A-2:${edid}.edid \
vc4.force_hotplug=0x03"
  else
    cmdline="$cmdline \
drm.edid_firmware=HDMI-A-1:${edid}.edid \
vc4.force_hotplug=0x01"
  fi
fi

# Normalize whitespace again after appending multiline blocks.
cmdline="$(echo "$cmdline" | tr -s ' ' | sed -E 's/^ +| +$//g')"

# write the updated cmdline back to the file
step_begin "Writing boot cmdline configuration"
if echo "$cmdline" > /boot/firmware/cmdline.txt; then
  step_ok
else
  step_error "Unable to write /boot/firmware/cmdline.txt"
fi

# create default application user if necessary
step_begin "Ensuring user '$app_user' exists"
if grep "^$app_user:" /etc/passwd > /dev/null 2>&1; then
  step_ok
else
  if run_quiet useradd -s /bin/bash -p "$(openssl passwd -6 "$app_password")" "$app_user" --create-home; then
    step_ok
  else
    step_error "Failed to create user '$app_user'"
  fi
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
  run_step "Adding '$app_user' to supplemental groups: $available_groups" usermod -aG "$available_groups" "$app_user"
else
  step_begin "No supplemental kiosk groups found to add"
  step_ok
fi

app_uid=$(id -u "$app_user")

# enable seatd for Wayland compositor seat management
run_step "Enabling seatd service" systemctl enable seatd

# fully disable getty on tty1 to prevent any console login prompt from returning
run_step "Stopping/disabling getty on tty1" systemctl disable --now getty@tty1.service
run_step "Masking getty on tty1" systemctl mask getty@tty1.service

# disable automatic virtual-console getty spawning to prevent tty login prompts
# from reappearing when the graphical session stops during reboot/shutdown.
step_begin "Disabling automatic virtual-console getty spawning"
if run_quiet sed -E -i \
  -e 's/^[[:space:]]*#?[[:space:]]*NAutoVTs=.*/NAutoVTs=0/' \
  -e 's/^[[:space:]]*#?[[:space:]]*ReserveVT=.*/ReserveVT=0/' \
  /etc/systemd/logind.conf; then
  if ! grep -Eq '^[[:space:]]*NAutoVTs=' /etc/systemd/logind.conf; then
    if ! run_quiet sh -c "printf '\nNAutoVTs=0\n' >> /etc/systemd/logind.conf"; then
      step_error "Unable to set NAutoVTs in /etc/systemd/logind.conf"
    fi
  fi
  if ! grep -Eq '^[[:space:]]*ReserveVT=' /etc/systemd/logind.conf; then
    if ! run_quiet sh -c "printf 'ReserveVT=0\n' >> /etc/systemd/logind.conf"; then
      step_error "Unable to set ReserveVT in /etc/systemd/logind.conf"
    fi
  fi
  step_ok
else
  step_error "Unable to update /etc/systemd/logind.conf"
fi

# create compositor/session startup files
run_step "Creating kiosk config directories" su "$app_user" -c "mkdir -p ~/.config/labwc ~/.config/systemd/user ~/.local/bin"
step_begin "Enabling linger for '$app_user'"
if run_quiet loginctl enable-linger "$app_user"; then
  step_ok
else
  step_error_continue "Could not enable linger for '$app_user'"
fi

# Ensure a user manager exists now so user services can be managed before first login.
step_begin "Starting user manager for '$app_user'"
if run_quiet systemctl start "user@$app_uid.service"; then
  step_ok
else
  step_error_continue "Could not start user@$app_uid.service right now"
fi

# set system-wide dark mode preference for GTK apps (including squeekboard)
step_begin "Setting GTK dark mode preference"
if run_quiet su "$app_user" -c "gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'"; then
  step_ok
else
  step_error_continue "Could not apply GTK dark mode preference"
fi
if [ $rpi_connect -eq 1 ]; then
  step_begin "Enabling Raspberry Pi Connect user services"
  if [ -f /usr/lib/systemd/user/rpi-connect.service ]; then
    systemctl --global enable rpi-connect.service >/dev/null 2>&1 || true
  fi
  if [ -f /usr/lib/systemd/user/rpi-connect-wayvnc.service ]; then
    systemctl --global enable rpi-connect-wayvnc.service >/dev/null 2>&1 || true
  fi
  if [ -f /usr/lib/systemd/user/rpi-connect-signin.path ]; then
    systemctl --global enable rpi-connect-signin.path >/dev/null 2>&1 || true
  fi
  su "$app_user" -c "XDG_RUNTIME_DIR=/run/user/$app_uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus systemctl --user start rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path" >/dev/null 2>&1 || true
  step_ok
  labwc_connect_autostart=$(cat <<'EOF'

# Keep user systemd/dbus environment aligned with this Wayland session.
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP

# Restart screen-sharing backend now that Wayland env is present.
systemctl --user restart rpi-connect-wayvnc.service >/dev/null 2>&1 || true
EOF
)
else
  step_begin "Disabling Raspberry Pi Connect user services"
  systemctl --global disable rpi-connect.service >/dev/null 2>&1 || true
  systemctl --global disable rpi-connect-wayvnc.service >/dev/null 2>&1 || true
  systemctl --global disable rpi-connect-signin.path >/dev/null 2>&1 || true
  step_ok
  labwc_connect_autostart=""
fi
run_step "Creating labwc config directory" su "$app_user" -c "mkdir -p ~/.config/labwc"
step_begin "Writing labwc rc.xml"
if cat << 'EOF' > /home/$app_user/.config/labwc/rc.xml; then
<?xml version="1.0"?>
<labwc_config>
  <core>
    <!-- Prefer client-side decorations so Chromium negotiates via xdg-decoration. -->
    <decoration>client</decoration>
  </core>

  <theme>
    <!-- Zero-size fallback theme: if SSD is applied despite the above, it renders invisibly. -->
    <name>kiosk</name>
  </theme>

  <windowRules>

    <!-- Hide cursor on first mapped window so kiosk starts pointer-free. -->
    <windowRule identifier="*" matchOnce="true">
      <action name="HideCursor" />
    </windowRule>

    <!-- Belt-and-suspenders: disable SSD for every window regardless of app_id. -->
    <windowRule identifier="*" serverDecoration="no" />

    <!-- Move to output HDMI-A-1 based on app_id -->
    <windowRule identifier="*HDMI-A-1*">
      <action name="MoveToOutput" output="HDMI-A-1" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Move to output HDMI-A-1 based on window title -->
    <windowRule title="*HDMI-A-1*">
      <action name="MoveToOutput" output="HDMI-A-1" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Move to output HDMI-A-2 based on app_id -->
    <windowRule identifier="*HDMI-A-2*">
      <action name="MoveToOutput" output="HDMI-A-2" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Move to output HDMI-A-2 based on window title -->
    <windowRule title="*HDMI-A-2*">
      <action name="MoveToOutput" output="HDMI-A-2" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Maximize based on app_id -->
    <windowRule identifier="*Maximized*">
      <action name="Maximize" />
    </windowRule>

    <!-- Maximize based on window title -->
    <windowRule title="*Maximized*">
      <action name="Maximize" />
    </windowRule>

  </windowRules>
</labwc_config>
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.config/labwc/rc.xml"
fi
# Create a zero-size labwc theme so even if SSD is applied it renders invisibly
run_step "Setting ownership for labwc config" chown "$app_user:$app_user" "/home/$app_user/.config/labwc/rc.xml"
run_step "Creating kiosk theme directory" su "$app_user" -c "mkdir -p ~/.local/share/themes/kiosk/openbox-3"
step_begin "Writing kiosk theme configuration"
if cat << 'EOF' > /home/$app_user/.local/share/themes/kiosk/openbox-3/themerc; then
border.width: 0
padding.width: 0
padding.height: 0
titlebar.height: 0
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.local/share/themes/kiosk/openbox-3/themerc"
fi
run_step "Setting ownership for kiosk theme files" chown -R "$app_user:$app_user" "/home/$app_user/.local/share/themes"
step_begin "Writing labwc autostart script"
if cat << EOF > /home/$app_user/.config/labwc/autostart; then
#!/bin/sh
$labwc_connect_autostart
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.config/labwc/autostart"
fi
run_step "Setting labwc autostart ownership" chown "$app_user:$app_user" "/home/$app_user/.config/labwc/autostart"
run_step "Making labwc autostart executable" chmod +x "/home/$app_user/.config/labwc/autostart"

if [ "$edid" != "none" ]; then
  kiosk_force_mode=1
  kiosk_mode="1920x1080"
else
  kiosk_force_mode=0
  kiosk_mode=""
fi
kiosk_num_displays=$displays

step_begin "Writing kiosk session launcher"
if cat << EOF > /home/$app_user/.local/bin/kiosk; then
#!/usr/bin/env bash
set -euo pipefail

export HOME="/home/$app_user"
export XDG_RUNTIME_DIR="/run/user/$app_uid"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="labwc"
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland,x11
export SDL_VIDEODRIVER=wayland
export GTK_THEME=Adwaita:dark
export GTK_IM_MODULE=wayland
export QT_IM_MODULE=wayland
export SDL_IM_MODULE=wayland
export XMODIFIERS=@im=wayland

FORCE_MODE="$kiosk_force_mode"
MODE="$kiosk_mode"
NUM_DISPLAYS="$kiosk_num_displays"
TARGET_WAYLAND_DISPLAY="wayland-0"

WAIT_SECS=20
APPLY_RETRIES=20
APPLY_RETRY_DELAY_SECS=0.5

log() { echo "kiosk: \$*"; }

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

start_kiosk_target() {
  log "Layout applied successfully."
  export WAYLAND_DISPLAY="\$TARGET_WAYLAND_DISPLAY"
  systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP GTK_THEME || true
  if systemctl --user start kiosk.target; then
    log "Started kiosk.target."
  else
    log "Failed to start kiosk.target."
    return 1
  fi
}

init_kiosk_after_wayland_ready() {
  log "Waiting for Wayland socket..."
  if ! wait_for_socket "\$XDG_RUNTIME_DIR/\$TARGET_WAYLAND_DISPLAY" "\$WAIT_SECS"; then
    log "Timed out waiting for \$XDG_RUNTIME_DIR/\$TARGET_WAYLAND_DISPLAY"
    return 1
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
    return 1
  fi

  if [ "\$NUM_DISPLAYS" -eq 2 ] && [ -z "\${out2:-}" ]; then
    log "Could not find second HDMI output via wlr-randr. Full output state:"
    wayland_query || true
    return 1
  fi

  for _ in \$(seq 1 "\$APPLY_RETRIES"); do
    if [ "\$FORCE_MODE" -eq 1 ]; then
      if [ "\$NUM_DISPLAYS" -eq 2 ]; then
        if wlr-randr --output "\$out1" --on --mode "\$MODE" --pos 0,0 \
          && wlr-randr --output "\$out2" --on --mode "\$MODE" --pos 1920,0; then
          start_kiosk_target
          return \$?
        fi
      else
        if wlr-randr --output "\$out1" --on --mode "\$MODE" --pos 0,0; then
          start_kiosk_target
          return \$?
        fi
      fi
    else
      if [ "\$NUM_DISPLAYS" -eq 2 ]; then
        if wlr-randr --output "\$out1" --on --pos 0,0 \
          && wlr-randr --output "\$out2" --on; then
          start_kiosk_target
          return \$?
        fi
      else
        if wlr-randr --output "\$out1" --on --pos 0,0; then
          start_kiosk_target
          return \$?
        fi
      fi
    fi

    sleep "\$APPLY_RETRY_DELAY_SECS"
  done

  log "Failed to apply layout after retries. Current output state:"
  wayland_query || true
  return 1
}

if [ ! -d "\$XDG_RUNTIME_DIR" ] || [ ! -w "\$XDG_RUNTIME_DIR" ]; then
  echo "kiosk: XDG_RUNTIME_DIR '\$XDG_RUNTIME_DIR' is missing or not writable" >&2
  exit 1
fi

init_kiosk_after_wayland_ready &
exec dbus-run-session -- labwc
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.local/bin/kiosk"
fi
run_step "Setting session launcher ownership" chown "$app_user:$app_user" "/home/$app_user/.local/bin/kiosk"
run_step "Making session launcher executable" chmod +x "/home/$app_user/.local/bin/kiosk"

# create local static app files and browser launchers
run_step "Creating browser profile/settings directories" su "$app_user" -c "mkdir -p ~/applications/kioskbrowser-1/profile ~/applications/kioskbrowser-1/settings ~/applications/kioskbrowser-2/profile ~/applications/kioskbrowser-2/settings"
create_kioskbrowser_index() {
  local browser_num="$1"
  local settings_dir="~/applications/kioskbrowser-${browser_num}/settings"
  local tint="$2"

  cat << EOF > /home/$app_user/applications/kioskbrowser-${browser_num}/index.html || return 1
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kiosk Browser ${browser_num}</title>

  <style>
    :root {
      color-scheme: dark;

      --tint: oklch(0.68 0.14 ${tint}); 
      /* Change only --tint to shift blue/green theme flavor. */
      --bg-a: color-mix(in oklab, black 70%, var(--tint) 30%);
      --bg-b: color-mix(in oklab, black 78%, var(--tint) 22%);
      --ink: color-mix(in oklab, white 82%, var(--tint) 18%);
      --accent: color-mix(in oklab, var(--tint) 78%, white 22%);
      --accent-dark: color-mix(in oklab, var(--tint) 68%, black 32%);
      --danger: #f87070;
      --success: #4cd97a;
      --card-bg: color-mix(in oklab, black 62%, var(--tint) 38%);
      --card-border: color-mix(in oklab, var(--ink) 26%, transparent);
      --repo-card-bg: color-mix(in oklab, white 44%, var(--accent) 96%);
      --repo-card-ink: color-mix(in oklab, black 54%, var(--accent-dark) 46%);
      --card-shadow: rgba(0, 0, 0, 0.55);
      --field-border: color-mix(in oklab, black 55%, var(--tint) 45%);
      --field-bg: color-mix(in oklab, black 72%, var(--tint) 28%);
      --button-bg: color-mix(in oklab, var(--accent) 82%, black 18%);
      --button-bg-hover: color-mix(in oklab, var(--accent-dark) 84%, black 16%);

      /* Watermark settings: adjust SVG width/height for tile spacing. */
      --page-bg: radial-gradient(circle at 20% 20%, color-mix(in oklab, var(--bg-a) 88%, white 12%) 0%, var(--bg-a) 45%, var(--bg-b) 100%);
      --watermark: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='160' viewBox='0 0 240 160'%3E%3Ctext x='120' y='80' dominant-baseline='middle' text-anchor='middle' transform='rotate(-45 120 80)' font-family='Noto Sans, Segoe UI, Arial, sans-serif' font-size='34' font-weight='700' letter-spacing='3' fill='rgba(120,160,255,0.12)'%3EDISPLAY ${browser_num}%3C/text%3E%3C/svg%3E");
    }

    * {
      box-sizing: border-box;
    }

    html {
      min-height: 100%;
    }

    body {
      min-height: 100vh;
      margin: 0;
      position: relative;
      isolation: isolate;
      display: grid;
      place-items: center;
      padding: clamp(1.25rem, 4vw, 3rem);
      color: var(--ink);
      font-family: "Noto Sans", "Segoe UI", sans-serif;
      background-image: var(--page-bg);
      background-repeat: no-repeat;
      background-size: cover;
      background-attachment: fixed;
    }

    body::before {
      content: "";
      position: fixed;
      inset: -160px -240px;
      z-index: 0;
      pointer-events: none;
      background-image: var(--watermark);
      background-repeat: repeat;
      background-size: 240px 160px;
      will-change: transform;
      animation: drift 15s linear infinite;
    }

    @keyframes drift {
      from { transform: translate3d(0, 0, 0); }
      to   { transform: translate3d(240px, 160px, 0); }
    }

    main {
      position: relative;
      z-index: 1;
      width: min(90vw, 900px);
      padding: clamp(2rem, 5vw, 3rem);
      border-radius: 1.2rem;
      background: color-mix(in oklab, var(--card-bg) 88%, transparent);
      border: 1px solid var(--card-border);
      box-shadow: 0 1rem 3rem var(--card-shadow);
      text-align: center;
      backdrop-filter: blur(2px);
    }

    .repo-card {
      position: fixed;
      z-index: 1;
      left: 50%;
      bottom: clamp(1rem, 2.5vw, 2rem);
      transform: translateX(-50%);
      width: min(90vw, 900px);
      padding: 0.65rem 1rem;
      border-radius: 0.9rem;
      background: color-mix(in oklab, var(--repo-card-bg) 92%, transparent);
      box-shadow: 0 0.6rem 1.8rem rgba(0, 0, 0, 0.35);
      text-align: center;
      backdrop-filter: blur(2px);
      color: var(--repo-card-ink);
    }

    .repo-card-row {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .repo-card-left,
    .repo-card-right {
      flex: 1 1 50%;
    }

    .repo-card-left {
      text-align: left;
    }

    .repo-card-right {
      text-align: right;
    }

    .repo-card a {
      color: var(--repo-card-ink);
      font-weight: 600;
      text-decoration: none;
    }

    .repo-card a:hover,
    .repo-card a:focus-visible {
      color: color-mix(in oklab, var(--repo-card-ink) 80%, black 20%);
      text-decoration: underline;
    }

    h1 {
      margin: 0;
      font-size: clamp(2rem, 5vw, 3.25rem);
      line-height: 1.1;
      letter-spacing: 0.02em;
    }

    p {
      margin: 1rem 0 0;
      font-size: clamp(1rem, 2vw, 1.35rem);
      line-height: 1.5;
    }

    code {
      display: inline-block;
      max-width: 100%;
      margin-top: 0.8rem;
      margin-left: 2rem;
      margin-right: 2rem;
      padding: 0.5rem 0.75rem;
      border-radius: 0.5rem;
      color: #ffffff;
      background: color-mix(in oklab, var(--accent-dark) 82%, black 18%);
      font-size: 0.95rem;
      line-height: 1.45;
      white-space: normal;
    }

    form {
      margin-top: 1.5rem;
      display: grid;
      gap: 0.75rem;
      justify-items: center;
    }

    .url-row {
      width: min(100%, 720px);
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 0.75rem;
    }

    input[type="text"] {
      width: 100%;
      min-width: 0;
      padding: 0.8rem 0.95rem;
      border: 1px solid var(--field-border);
      border-radius: 0.65rem;
      color: var(--ink);
      background: var(--field-bg);
      font: inherit;
      font-size: 1rem;
    }

    input[type="text"]:focus {
      border-color: var(--accent);
      outline: 3px solid color-mix(in oklab, var(--accent) 35%, transparent);
      outline-offset: 0;
    }

    button {
      border: 0;
      border-radius: 0.65rem;
      padding: 0.8rem 1rem;
      color: #ffffff;
      background: var(--button-bg);
      font: inherit;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
    }

    button:focus-visible {
      outline: 3px solid color-mix(in oklab, var(--accent) 45%, transparent);
      outline-offset: 2px;
    }

    button:hover:not(:disabled) {
      background: var(--button-bg-hover);
    }

    button:disabled {
      opacity: 0.7;
      cursor: wait;
    }

    #status {
      min-height: 1.4em;
      margin-top: 0.25rem;
      font-size: 0.95rem;
    }

    #status.error {
      color: var(--danger);
    }

    #status.ok {
      color: var(--success);
    }

    @media (max-width: 700px) {
      .url-row {
        grid-template-columns: 1fr;
      }

      button {
        width: 100%;
      }

      .repo-card-row {
        flex-direction: column;
        align-items: stretch;
        gap: 0.35rem;
      }

      .repo-card-left,
      .repo-card-right {
        text-align: center;
      }
    }
  </style>
</head>

<body>
  <main>
    <h1>Display ${browser_num}</h1>
    <p>This is a full screen chromium browser window displaying a local HTML file.</p>

    <form id="set-start-page-form">
      <div class="url-row">
        <input id="start-url" type="text" inputmode="url" autocomplete="off" spellcheck="false" placeholder="https://example.com" aria-label="Start page URL">
        <button id="set-start-page" type="submit">Set start page</button>
      </div>
      <div id="status" aria-live="polite"></div>
    </form>

    <code>Enter the desired startup URL and press <b><i>Set start page</i></b>.  In the file picker that pops up, select <b><i>${settings_dir}</i></b> and press <b><i>Open</i></b>.  The selected URL will be saved and used as the startup page.</code>
  </main>

  <aside class="repo-card">
    <div class="repo-card-row">
      <div class="repo-card-left">
        Raspberry Pi Kiosk Cooker ${SCRIPT_VERSION} by <a href="https://github.com/fasteddy516" target="_blank" rel="noopener noreferrer">fasteddy516</a>
      </div>
      <div class="repo-card-right">
        <a href="https://github.com/fasteddy516/pi-kiosk-cooker" target="_blank" rel="noopener noreferrer">github.com/fasteddy516/pi-kiosk-cooker</a>
      </div>
    </div>
  </aside>

  <script>
    const form = document.getElementById('set-start-page-form');
    const input = document.getElementById('start-url');
    const button = document.getElementById('set-start-page');
    const statusEl = document.getElementById('status');

    function setStatus(message, kind) {
      statusEl.textContent = message;
      statusEl.className = kind || '';
    }

    function normalizeUrl(value) {
      const trimmed = value.trim();
      if (!trimmed) {
        return null;
      }

      const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed);
      const prefixed = hasScheme ? trimmed : 'https://' + trimmed;

      try {
        const url = new URL(prefixed);
        if (url.protocol === 'http:' || url.protocol === 'https:' || url.protocol === 'file:') {
          return url.toString();
        }
      } catch (_) {
        return null;
      }

      return null;
    }

    async function writeStartupUrl(url) {
      if (!window.showDirectoryPicker) {
        throw new Error('File write API not available in this Chromium build.');
      }

      const dirHandle = await window.showDirectoryPicker({ mode: 'readwrite' });
      const fileHandle = await dirHandle.getFileHandle('startup_url.txt', { create: true });
      const writable = await fileHandle.createWritable();
      await writable.write(url + '\n');
      await writable.close();
    }

    form.addEventListener('submit', async (event) => {
      event.preventDefault();

      const normalizedUrl = normalizeUrl(input.value);
      if (!normalizedUrl) {
        setStatus('Enter a valid http(s) or file URL.', 'error');
        input.focus();
        return;
      }

      button.disabled = true;
      setStatus('Saving startup_url.txt...', '');

      try {
        await writeStartupUrl(normalizedUrl);
        setStatus('Saved. Navigating now...', 'ok');
      } catch (error) {
        setStatus('Could not save startup_url.txt automatically: ' + error.message + ' Navigating anyway.', 'error');
      }

      setTimeout(() => {
        window.location.href = normalizedUrl;
      }, 300);
    });
  </script>
</body>
</html>
EOF

  chown "$app_user:$app_user" "/home/$app_user/applications/kioskbrowser-${browser_num}/index.html"
}

create_kioskbrowser_launcher() {
  local browser_num="$1"
  local output_name="$2"

  cat << EOF > /home/$app_user/applications/kioskbrowser-${browser_num}/start.sh || return 1
#!/usr/bin/env bash
set -euo pipefail

export HOME="\$HOME"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-wayland-0}"
export XDG_SESSION_TYPE="wayland"

if command -v chromium-browser >/dev/null 2>&1; then
  BROWSER_BIN="chromium-browser"
elif command -v chromium >/dev/null 2>&1; then
  BROWSER_BIN="chromium"
else
  echo "No Chromium browser binary found" >&2
  exit 1
fi

APP_DIR="\$HOME/applications/kioskbrowser-${browser_num}"
PROFILE_DIR="\$APP_DIR/profile"
URL_FILE="\$APP_DIR/settings/startup_url.txt"
DEFAULT_URL="file://\$APP_DIR/index.html"
START_URL="\$DEFAULT_URL"
OUTPUT_NAME="${output_name}-Maximized"

if [ -f "\$URL_FILE" ]; then
  raw_url="\$(head -n 1 "\$URL_FILE" | tr -d '\r')"
else
  raw_url=""
fi

if [ -n "\$raw_url" ]; then
  raw_url="\$(echo "\$raw_url" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+\$//')"
  if [[ "\$raw_url" =~ ^https?:// ]] || [[ "\$raw_url" =~ ^file:// ]]; then
    START_URL="\$raw_url"
  else
    echo "Ignoring invalid startup URL from settings file: '\$raw_url'" >&2
  fi
fi

mkdir -p "\$PROFILE_DIR"

exec "\$BROWSER_BIN" \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform,VirtualKeyboard,WaylandWindowDecorations,WebContentsForceDark \
  --disable-features=Translate,MediaRouter,AutofillServerCommunication \
  --enable-wayland-ime \
  --enable-virtual-keyboard \
  --force-dark-mode \
  --touch-events=enabled \
  --app="\$START_URL" \
  --no-first-run \
  --no-default-browser-check \
  --disable-session-crashed-bubble \
  --disable-infobars \
  --check-for-update-interval=31536000 \
  --user-data-dir="\$PROFILE_DIR" \
  --profile-directory="\$OUTPUT_NAME"
EOF

  chown "$app_user:$app_user" "/home/$app_user/applications/kioskbrowser-${browser_num}/start.sh"
  chmod +x "/home/$app_user/applications/kioskbrowser-${browser_num}/start.sh"
}

run_step "Generating browser 1 local start page" create_kioskbrowser_index 1 250
run_step "Generating browser 2 local start page" create_kioskbrowser_index 2 160

run_step "Generating browser 1 launcher" create_kioskbrowser_launcher 1 "HDMI-A-1"
run_step "Generating browser 2 launcher" create_kioskbrowser_launcher 2 "HDMI-A-2"

# add kiosk.service to start the graphical session on tty1 at boot
step_begin "Writing kiosk.service"
if cat << EOF > /etc/systemd/system/kiosk.service; then
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

TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
PAMName=login

ExecStart=/home/$app_user/.local/bin/kiosk
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  step_ok
else
  step_error "Unable to write /etc/systemd/system/kiosk.service"
fi

# create systemd service for the on-screen touch keyboard (if applicable)
if [ -n "$touch_keyboard_package" ]; then
  step_begin "Writing touchkeyboard.service"
  if cat << EOF > /home/$app_user/.config/systemd/user/touchkeyboard.service; then
[Unit]
Description=Kiosk on-screen touch keyboard
PartOf=kiosk.target
After=kiosk.target

[Service]
Type=simple
Environment=GTK_THEME=Adwaita:dark
ExecStart=/usr/bin/squeekboard
Restart=on-failure
RestartSec=2

[Install]
WantedBy=kiosk.target
EOF
    step_ok
  else
    step_error "Unable to write /home/$app_user/.config/systemd/user/touchkeyboard.service"
  fi
fi

create_kioskbrowser_service() {
  local browser_num="$1"
  cat << EOF > /home/$app_user/.config/systemd/user/kioskbrowser-${browser_num}.service || return 1
[Unit]
Description=Kiosk browser on display $browser_num
PartOf=kiosk.target
After=kiosk.target

[Service]
Type=simple
ExecStart=/home/$app_user/applications/kioskbrowser-${browser_num}/start.sh
Restart=always
RestartSec=2

[Install]
WantedBy=kiosk.target
EOF
}

# create kiosk user target and browser services for display 1 and display 2
step_begin "Writing kiosk.target user unit"
if cat << EOF > /home/$app_user/.config/systemd/user/kiosk.target; then
[Unit]
Description=Kiosk User Services
StopWhenUnneeded=no
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.config/systemd/user/kiosk.target"
fi
run_step "Setting kiosk user systemd unit ownership" chown -R "$app_user:$app_user" "/home/$app_user/.config/systemd"

# create browser services for display 1 and display 2
run_step "Writing kioskbrowser-1.service" create_kioskbrowser_service 1
run_step "Writing kioskbrowser-2.service" create_kioskbrowser_service 2
run_step "Setting kiosk browser user service ownership" chown "$app_user:$app_user" "/home/$app_user/.config/systemd/user/kioskbrowser-1.service" "/home/$app_user/.config/systemd/user/kioskbrowser-2.service"

# finish setting up systemd services and targets
run_step "Reloading systemd daemon" systemctl daemon-reload
run_user_systemctl "Reloading kiosk user systemd daemon" daemon-reload
run_step "Enabling kiosk.service" systemctl enable kiosk.service
if [ -n "$touch_keyboard_package" ]; then
  run_user_systemctl "Enabling touchkeyboard.service for '$app_user'" enable touchkeyboard.service
else
  run_user_systemctl_allow_nonzero "Disabling touchkeyboard.service for '$app_user'" disable --now touchkeyboard.service
fi
if [ "$default_application" -eq 1 ]; then
  run_user_systemctl "Enabling kioskbrowser-1.service for '$app_user'" enable kioskbrowser-1.service
  if [ "$displays" -eq 2 ]; then
    run_user_systemctl "Enabling kioskbrowser-2.service for '$app_user'" enable kioskbrowser-2.service
  else
    run_user_systemctl "Disabling kioskbrowser-2.service for '$app_user'" disable --now kioskbrowser-2.service
  fi
else
  run_user_systemctl "Disabling default kiosk browser services for '$app_user'" disable --now kioskbrowser-1.service kioskbrowser-2.service
fi

# remind about rpi-connect signin if applicable
if [ $rpi_connect -eq 1 ]; then
  print_line ""
  print_line "${C_BRIGHT_WHITE}*** IMPORTANT: Raspberry Pi Connect requires a one-time sign-in to link this"
  print_line "    device to your Raspberry Pi ID.  Log in as '$app_user' and run:${C_RESET}"
  print_line ""
  print_line "${C_WHITE}       rpi-connect signin${C_RESET}"
  print_line ""
  print_line "${C_BRIGHT_WHITE}    If you are signed in as another admin user, run these commands instead:${C_RESET}"
  print_line ""
  print_line "${C_WHITE}       sudo systemctl start user@$app_uid.service"
  print_line "       sudo -u $app_user XDG_RUNTIME_DIR=/run/user/$app_uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus rpi-connect signin${C_RESET}"
  print_line ""
  print_line "${C_BRIGHT_WHITE}    Visit the URL it displays to authorize this device.${C_RESET}"
fi

# all done - countdown to reboot
if [ $reboot -eq 1 ]; then
  print_line ""
  for i in $(seq 30 -1 1) ; do echo -ne "\r${C_BRIGHT_RED}*** Rebooting in $i seconds.  (CTRL-C to cancel) ***${C_RESET}" ; sleep 1 ; done
  print_line ""
  run_step "Rebooting system" reboot
else
  print_line ""
  print_line "${C_YELLOW}*** A reboot is strongly suggested before using the kiosk setup.  Run: sudo reboot${C_RESET}"
  print_line ""
fi
