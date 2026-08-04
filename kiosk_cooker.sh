#!/bin/bash

# kiosk_cooker version (used by script and generated UI text)
SCRIPT_VERSION="1.4.0"

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
KEEP_COMMAND_LOGS=0

print_line() {
  printf '%b\n' "$1"
}

init_command_logs() {
  COMMAND_STDOUT_LOG="$(mktemp /tmp/pi-kiosk-cooker-stdout.XXXXXX)" || return 1
  COMMAND_STDERR_LOG="$(mktemp /tmp/pi-kiosk-cooker-stderr.XXXXXX)" || return 1
}

cleanup_command_logs() {
  [ "$KEEP_COMMAND_LOGS" -eq 1 ] && return
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
  KEEP_COMMAND_LOGS=1
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

  run_step "$text" runuser -u "$app_user" -- env \
    "XDG_RUNTIME_DIR=/run/user/$app_uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus" \
    systemctl --user "$@"
}

run_user_systemctl_allow_nonzero() {
  local text="$1"
  shift

  run_step_allow_nonzero "$text" runuser -u "$app_user" -- env \
    "XDG_RUNTIME_DIR=/run/user/$app_uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus" \
    systemctl --user "$@"
}

run_systemctl_for_user_allow_nonzero() {
  local text="$1"
  local target_user="$2"
  local target_uid="$3"
  shift 3

  run_step_allow_nonzero "$text" runuser -u "$target_user" -- env \
    "XDG_RUNTIME_DIR=/run/user/$target_uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$target_uid/bus" \
    systemctl --user "$@"
}

run_rpi_connect_for_user_allow_nonzero() {
  local text="$1"
  local target_user="$2"
  local target_uid="$3"
  shift 3

  run_step_allow_nonzero "$text" runuser -u "$target_user" -- env \
    "XDG_RUNTIME_DIR=/run/user/$target_uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$target_uid/bus" \
    rpi-connect "$@"
}

configure_wireless_overlays() {
  local config_file="/boot/firmware/config.txt"
  local temp_file

  temp_file="$(mktemp)" || return 1

  awk -v disable_all_wireless="$disable_all_wireless" '
    BEGIN {
      in_all = 0
      all_seen = 0
      overlays_added = 0
    }

    function add_wireless_overlays() {
      if (disable_all_wireless == "1" && overlays_added == 0) {
        print "dtoverlay=disable-wifi"
        print "dtoverlay=disable-bt"
        overlays_added = 1
      }
    }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_all) {
        add_wireless_overlays()
      }

      in_all = ($0 ~ /^[[:space:]]*\[all\][[:space:]]*$/)
      if (in_all) {
        all_seen = 1
      }

      print
      next
    }

    in_all && /^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*disable-(wifi|bt)[[:space:]]*$/ {
      next
    }

    {
      print
    }

    END {
      if (in_all) {
        add_wireless_overlays()
      } else if (all_seen == 0 && disable_all_wireless == "1") {
        print ""
        print "[all]"
        add_wireless_overlays()
      }
    }
  ' "$config_file" > "$temp_file" && cat "$temp_file" > "$config_file"
  local status=$?

  rm -f "$temp_file"
  return "$status"
}

connector_from_menu_choice() {
  case "$1" in
    1) echo "HDMI-A-1" ;;
    2) echo "HDMI-A-2" ;;
    3) echo "DSI-1" ;;
    4) echo "DSI-2" ;;
    *) echo "" ;;
  esac
}

normalize_connector_value() {
  local value="$1"
  local mapped

  mapped="$(connector_from_menu_choice "$value")"
  if [ -n "$mapped" ]; then
    echo "$mapped"
  else
    echo "$value"
  fi
}

is_supported_connector() {
  case "$1" in
    HDMI-A-1|HDMI-A-2|DSI-1|DSI-2)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_kmsprint_available() {
  if ! command -v kmsprint >/dev/null 2>&1; then
    fail "kmsprint is required for display connector detection but was not found"
  fi
}

kmsprint_cache=""

refresh_kmsprint_cache() {
  if ! kmsprint_cache="$(kmsprint 2>/dev/null)"; then
    fail "Failed to query display connectors via kmsprint"
  fi
}

connector_kmsprint_line() {
  local connector="$1"
  printf '%s\n' "$kmsprint_cache" | grep -E "(^|[^A-Z0-9-])${connector}([^A-Z0-9-]|$)" | head -n 1
}

connector_exists() {
  local connector="$1"
  [ -n "$(connector_kmsprint_line "$connector")" ]
}

connector_is_active() {
  local connector="$1"
  local line

  line="$(connector_kmsprint_line "$connector")"
  if [ -z "$line" ]; then
    return 1
  fi

  echo "$line" | grep -Eqi 'connected|enabled|active'
}

print_connector_options() {
  local logical_display="$1"
  local choice connector

  print_line "Select connector:"
  for choice in 1 2 3 4; do
    connector="$(connector_from_menu_choice "$choice")"
    if [ "$logical_display" = "2" ] && [ -n "$display_1_output" ] && [ "$connector" = "$display_1_output" ]; then
      print_line "  $choice) ($connector) [assigned as Display 1]"
    elif connector_exists "$connector"; then
      print_line "  $choice) $connector [detected]"
    else
      print_line "  $choice) $connector"
    fi
  done
}

prompt_display_count() {
  local answer

  while true; do
    printf 'How many displays should be configured? (1 or 2): '
    IFS= read -r answer
    case "$answer" in
      1|2)
        displays="$answer"
        return 0
        ;;
      *)
        print_line "! Invalid value '$answer' (must be 1 or 2)"
        ;;
    esac
  done
}

prompt_display_connector() {
  local logical_display="$1"
  local target_var="$2"
  local answer connector

  while true; do
    refresh_kmsprint_cache
    print_line ""
    print_connector_options "$logical_display"
    printf 'Select output for display %s (1-4): ' "$logical_display"
    IFS= read -r answer
    connector="$(connector_from_menu_choice "$answer")"
    if [ -z "$connector" ]; then
      print_line "! Invalid selection '$answer' (must be 1, 2, 3, or 4)"
      continue
    fi
    if [ "$logical_display" = "2" ] && [ -n "$display_1_output" ] && [ "$connector" = "$display_1_output" ]; then
      print_line "! '$connector' is already assigned as Display 1"
      continue
    fi
    printf -v "$target_var" '%s' "$connector"
    return 0
  done
}

save_display_config() {
  run_step "Creating kiosk display config directory" mkdir -p "$display_config_dir"

  step_begin "Writing kiosk display config"
  if cat > "$display_config_file" << EOF; then
# Managed by pi-kiosk-cooker
displays=$displays
display_1_output=$display_1_output
display_2_output=$display_2_output
display_1_touch_device=$display_1_touch_device
display_2_touch_device=$display_2_touch_device
EOF
    step_ok
  else
    step_error "Unable to write $display_config_file"
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

print_line "${C_RED}🔥${C_RESET}${C_LIGHT_BLUE} pi-kiosk-cooker ${SCRIPT_VERSION} by fasteddy516${C_RESET}"

# ensure the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
  fail "This script must be run as root (i.e. with sudo)"
fi

if ! init_command_logs; then
  fail "Unable to create temporary command log files under /tmp"
fi
trap cleanup_command_logs EXIT

# suppress interactive prompts from apt/dpkg for the duration of this script
export DEBIAN_FRONTEND=noninteractive

# set default application username if it hasn't been specified
if [ ! -v app_user ]; then
  app_user=kiosk
fi

# application password has no default; it is required when creating app_user

# set default number of displays if it hasn't been specified
if [ ! -v displays ]; then
  displays=""
fi

# set default logical output mapping (resolved during stage 2 selection)
if [ ! -v display_1_output ]; then
  display_1_output=""
fi
if [ ! -v display_2_output ]; then
  display_2_output=""
fi

# one touch device per logical display (stage 1 scaffolding)
if [ ! -v display_1_touch_device ]; then
  display_1_touch_device=""
fi
if [ ! -v display_2_touch_device ]; then
  display_2_touch_device=""
fi

# set default video kernel command-line entries if they haven't been specified
if [ ! -v video ]; then
  video=()
fi

# set default apt upgrade state if it hasn't been specified
if [ ! -v apt_upgrade ]; then
  apt_upgrade=1
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

# set default wireless hardware/service state if it hasn't been specified
if [ ! -v disable_all_wireless ]; then
  disable_all_wireless=0
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
displays_explicit=0
display_1_output_explicit=0
display_2_output_explicit=0
display_1_touch_device_explicit=0
display_2_touch_device_explicit=0
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
      displays_explicit=1
      if [ "$displays" != "1" ] && [ "$displays" != "2" ]; then
        fail "Invalid value for --displays: '$displays' (must be 1 or 2)"
      fi
      ;;
    --display-1-output=*)
      display_1_output="${arg#*=}"
      display_1_output_explicit=1
      ;;
    --display-2-output=*)
      display_2_output="${arg#*=}"
      display_2_output_explicit=1
      ;;
    --display-1-touch-device=*)
      display_1_touch_device="${arg#*=}"
      display_1_touch_device_explicit=1
      ;;
    --display-2-touch-device=*)
      display_2_touch_device="${arg#*=}"
      display_2_touch_device_explicit=1
      ;;
    --video=*)
      video+=("${arg#*=}")
      ;;
    --no-apt-upgrade)
      apt_upgrade=0
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
    --disable-all-wireless)
      disable_all_wireless=1
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

if [[ ! "$app_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  fail "Invalid value for --user: '$app_user' (must be a valid Linux username)"
fi

display_config_dir="/home/$app_user/.config/kiosk"
display_config_file="$display_config_dir/display-map.conf"

ensure_kmsprint_available

display_1_output="$(normalize_connector_value "$display_1_output")"
display_2_output="$(normalize_connector_value "$display_2_output")"

if [ -z "$displays" ]; then
  prompt_display_count
fi

if [ "$displays" != "1" ] && [ "$displays" != "2" ]; then
  fail "Invalid value for --displays: '$displays' (must be 1 or 2)"
fi

if [ -z "$display_1_output" ]; then
  prompt_display_connector "1" display_1_output
fi

if ! is_supported_connector "$display_1_output"; then
  fail "Invalid value for --display-1-output: '$display_1_output' (must be HDMI-A-1, HDMI-A-2, DSI-1, or DSI-2)"
fi

refresh_kmsprint_cache
if [ "$displays" = "2" ]; then
  if [ -z "$display_2_output" ]; then
    prompt_display_connector "2" display_2_output
  fi
  if ! is_supported_connector "$display_2_output"; then
    fail "Invalid value for --display-2-output: '$display_2_output' (must be HDMI-A-1, HDMI-A-2, DSI-1, or DSI-2)"
  fi
  if [ "$display_1_output" = "$display_2_output" ]; then
    fail "display_1_output and display_2_output cannot be the same when --displays=2"
  fi
else
  if [ -n "$display_2_output" ]; then
    print_line "${C_YELLOW}! note: ignoring display_2_output because displays=1${C_RESET}"
  fi
  display_2_output=""
fi

case "$edid" in
  none|1080P-2CH)
    ;;
  *)
    fail "Invalid value for --edid: '$edid' (supported values: none, 1080P-2CH)"
    ;;
esac

# require a non-empty password only when creating a new user
if ! getent passwd "$app_user" > /dev/null 2>&1 && [ -z "${app_password:-}" ]; then
  fail "Missing required argument for new user '$app_user': --password=<password>"
fi

# write remembered arguments (all args except --remember and --password)
if [ "$remember" -eq 1 ]; then
  step_begin "Saving remembered arguments to $memory_file"
  saved=()
  for arg in "${cli_args[@]}"; do
    case "$arg" in
      --remember|--password=*)
        ;;
      *)
        saved+=("$arg")
        ;;
    esac
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
if [ "$apt_upgrade" -eq 1 ]; then
  run_step "Upgrading installed packages (this may take a few minutes)" apt upgrade -y
else
  step_begin "Skipping apt upgrade via --no-apt-upgrade"
  step_ok
fi

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

if [ "$touch_keyboard" -eq 1 ]; then
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

kiosk_packages=(labwc wlr-randr wlopm wayland-protocols xwayland dbus-user-session seatd ddcutil "$browser_package")
if [ -n "$touch_keyboard_package" ]; then
  kiosk_packages+=("$touch_keyboard_package")
fi
if [ "$rpi_connect" -eq 1 ]; then
  kiosk_packages+=(rpi-connect)
fi
run_step "Installing required packages (this may take a few minutes)" apt install -y "${kiosk_packages[@]}"

# remove orphaned packages
run_step "Removing orphaned packages (this may take a few minutes)" apt autoremove -y

# configure Chromium managed policies
run_step "Creating Chromium policy directory" mkdir -p /etc/chromium/policies/managed
step_begin "Writing Chromium kiosk policy"
if cat << 'EOF' > /etc/chromium/policies/managed/kiosk.json; then
{
  "DeveloperToolsAvailability": 2
}
EOF
  step_ok
else
  step_error "Unable to write /etc/chromium/policies/managed/kiosk.json"
fi

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

# configure Raspberry Pi wireless overlays in the [all] section
if [ "$disable_all_wireless" -eq 1 ]; then
  run_step "Disabling Wi-Fi/Bluetooth firmware overlays" configure_wireless_overlays
else
  run_step "Enabling Wi-Fi/Bluetooth firmware overlays" configure_wireless_overlays
fi

# disable overscan for active hdmi outputs
run_step_allow_nonzero "Disabling overscan on HDMI-A-1" raspi-config nonint do_overscan_kms 1 1
if [ "$displays" -eq 2 ]; then
  run_step_allow_nonzero "Disabling overscan on HDMI-A-2" raspi-config nonint do_overscan_kms 2 1
fi

# disable screen blanking
run_step_allow_nonzero "Disabling screen blanking" raspi-config nonint do_blanking 1

# enable I2C for DDC display management
run_step_allow_nonzero "Enabling I2C bus for DDC display management" raspi-config nonint do_i2c 0

# install edid file if specified
if [ "$edid" != "none" ]; then
  run_step "Installing EDID firmware file" mv "./${edid}.edid" "/lib/firmware/${edid}.edid"
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
if getent passwd "$app_user" > /dev/null 2>&1; then
  if ! getent group "$app_user" > /dev/null 2>&1; then
    step_error "User '$app_user' already exists, but matching group '$app_user' does not exist"
  fi
  step_ok
  print_line "    ${C_YELLOW}! warning: user '$app_user' already exists; password will not be changed${C_RESET}"
else
  if run_quiet useradd -s /bin/bash -p "$(openssl passwd -6 "$app_password")" "$app_user" --create-home; then
    step_ok
  else
    step_error "Failed to create user '$app_user'"
  fi
fi

save_display_config
run_step "Setting ownership for kiosk display config" chown -R "$app_user:$app_user" "$display_config_dir"

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

# manage wireless services on a best-effort basis
if [ "$disable_all_wireless" -eq 1 ]; then
  run_step_allow_nonzero "Disabling wireless services" systemctl disable --now bluetooth.service wpa_supplicant.service
else
  run_step_allow_nonzero "Enabling wireless services" systemctl enable --now bluetooth.service wpa_supplicant.service
fi

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
if [ "$rpi_connect" -eq 1 ]; then
  rpi_connect_units=(rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path)
  invoking_user="${SUDO_USER:-$(id -un)}"

  run_step_allow_nonzero "Disabling global Raspberry Pi Connect user units" systemctl --global disable "${rpi_connect_units[@]}"

  if [ "$invoking_user" != "$app_user" ] && getent passwd "$invoking_user" >/dev/null 2>&1; then
    invoking_uid="$(id -u "$invoking_user")"
    run_step_allow_nonzero "Starting user manager for invoking user '$invoking_user'" systemctl start "user@$invoking_uid.service"
    run_systemctl_for_user_allow_nonzero "Disabling Raspberry Pi Connect for invoking user '$invoking_user'" "$invoking_user" "$invoking_uid" disable --now "${rpi_connect_units[@]}"
    run_rpi_connect_for_user_allow_nonzero "Signing out Raspberry Pi Connect for invoking user '$invoking_user'" "$invoking_user" "$invoking_uid" signout
    run_rpi_connect_for_user_allow_nonzero "Turning off Raspberry Pi Connect for invoking user '$invoking_user'" "$invoking_user" "$invoking_uid" off
  fi

  run_systemctl_for_user_allow_nonzero "Enabling Raspberry Pi Connect for '$app_user'" "$app_user" "$app_uid" enable --now "${rpi_connect_units[@]}"
  run_rpi_connect_for_user_allow_nonzero "Turning on Raspberry Pi Connect for '$app_user'" "$app_user" "$app_uid" on
  print_line "    ${C_YELLOW}! note: Raspberry Pi Connect service setup is best effort; missing units or command failures are ignored${C_RESET}"
  labwc_connect_autostart=$(cat <<'EOF'

# Keep user systemd/dbus environment aligned with this Wayland session.
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP

# Restart screen-sharing backend now that Wayland env is present.
systemctl --user restart rpi-connect-wayvnc.service >/dev/null 2>&1 || true
EOF
)
else
  rpi_connect_units=(rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path)
  run_step_allow_nonzero "Disabling global Raspberry Pi Connect user units" systemctl --global disable "${rpi_connect_units[@]}"
  run_user_systemctl_allow_nonzero "Disabling Raspberry Pi Connect for '$app_user'" disable --now "${rpi_connect_units[@]}"
  labwc_connect_autostart=""
fi
run_step "Creating labwc config directory" su "$app_user" -c "mkdir -p ~/.config/labwc"
step_begin "Writing display map runtime sync helper"
if cat << EOF > "/home/$app_user/.local/bin/kiosk-sync-display-map"; then
#!/usr/bin/env bash
set -euo pipefail

MAP_FILE="\$HOME/.config/kiosk/display-map.conf"
RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
ENV_DIR="\$RUNTIME_DIR/kiosk"
ENV_FILE="\$ENV_DIR/display-map.env"
RC_FILE="\$HOME/.config/labwc/rc.xml"

DEFAULT_DISPLAYS="$displays"
DEFAULT_DISPLAY_1_OUTPUT="$display_1_output"
DEFAULT_DISPLAY_2_OUTPUT="$display_2_output"

normalize_connector_value() {
  case "\$1" in
    1) printf '%s' "HDMI-A-1" ;;
    2) printf '%s' "HDMI-A-2" ;;
    3) printf '%s' "DSI-1" ;;
    4) printf '%s' "DSI-2" ;;
    *) printf '%s' "\$1" ;;
  esac
}

is_supported_connector() {
  case "\$1" in
    HDMI-A-1|HDMI-A-2|DSI-1|DSI-2)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

xml_escape() {
  local value="\$1"
  value="\${value//&/&amp;}"
  value="\${value//</&lt;}"
  value="\${value//>/&gt;}"
  value="\${value//\"/&quot;}"
  printf '%s' "\$value"
}

displays="\$DEFAULT_DISPLAYS"
display_1_output="\$DEFAULT_DISPLAY_1_OUTPUT"
display_2_output="\$DEFAULT_DISPLAY_2_OUTPUT"
display_1_touch_device=""
display_2_touch_device=""

if [ -f "\$MAP_FILE" ]; then
  while IFS= read -r line || [ -n "\$line" ]; do
    case "\$line" in
      ''|\#*)
        ;;
      displays=*)
        displays="\${line#*=}"
        ;;
      display_1_output=*)
        display_1_output="\${line#*=}"
        ;;
      display_2_output=*)
        display_2_output="\${line#*=}"
        ;;
      display_1_touch_device=*)
        display_1_touch_device="\${line#*=}"
        ;;
      display_2_touch_device=*)
        display_2_touch_device="\${line#*=}"
        ;;
    esac
  done < "\$MAP_FILE"
fi

display_1_output="\$(normalize_connector_value "\$display_1_output")"
display_2_output="\$(normalize_connector_value "\$display_2_output")"

if [ "\$displays" != "1" ] && [ "\$displays" != "2" ]; then
  displays="\$DEFAULT_DISPLAYS"
fi

if ! is_supported_connector "\$display_1_output"; then
  display_1_output="\$DEFAULT_DISPLAY_1_OUTPUT"
fi

if [ "\$displays" = "2" ]; then
  if ! is_supported_connector "\$display_2_output" || [ "\$display_2_output" = "\$display_1_output" ]; then
    display_2_output="\$DEFAULT_DISPLAY_2_OUTPUT"
  fi
  if ! is_supported_connector "\$display_2_output" || [ "\$display_2_output" = "\$display_1_output" ]; then
    for candidate in HDMI-A-1 HDMI-A-2 DSI-1 DSI-2; do
      if [ "\$candidate" != "\$display_1_output" ]; then
        display_2_output="\$candidate"
        break
      fi
    done
  fi
else
  display_2_output=""
fi

mkdir -p "\$(dirname "\$RC_FILE")"
if [ -d "\$RUNTIME_DIR" ] && [ -w "\$RUNTIME_DIR" ]; then
  mkdir -p "\$ENV_DIR"
  cat > "\$ENV_FILE" << ENV
KIOSK_NUM_DISPLAYS=\$displays
KIOSK_DISPLAY_1_OUTPUT=\$display_1_output
KIOSK_DISPLAY_2_OUTPUT=\$display_2_output
ENV
fi

labwc_touch_entries=""
if [ -n "\$display_1_touch_device" ]; then
  display_1_touch_device_xml="\$(xml_escape "\$display_1_touch_device")"
  labwc_touch_entries="  <touch deviceName=\"\$display_1_touch_device_xml\" mapToOutput=\"\$display_1_output\" mouseEmulation=\"yes\" />"
fi
if [ "\$displays" = "2" ] && [ -n "\$display_2_touch_device" ]; then
  display_2_touch_device_xml="\$(xml_escape "\$display_2_touch_device")"
  if [ -n "\$labwc_touch_entries" ]; then
    labwc_touch_entries="\$labwc_touch_entries
  <touch deviceName=\"\$display_2_touch_device_xml\" mapToOutput=\"\$display_2_output\" mouseEmulation=\"yes\" />"
  else
    labwc_touch_entries="  <touch deviceName=\"\$display_2_touch_device_xml\" mapToOutput=\"\$display_2_output\" mouseEmulation=\"yes\" />"
  fi
fi

labwc_display_2_rules=""
if [ "\$displays" = "2" ]; then
  labwc_display_2_rules="
    <!-- Move kiosk display 2 windows to the configured output -->
    <windowRule identifier=\"*KIOSK-D-2*\">
      <action name=\"MoveToOutput\" output=\"\$display_2_output\" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Move kiosk display 2 windows to the configured output by title -->
    <windowRule title=\"*KIOSK-D-2*\">
      <action name=\"MoveToOutput\" output=\"\$display_2_output\" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>"
fi

cat > "\$RC_FILE" << XML
<?xml version="1.0"?>
<labwc_config>

\${labwc_touch_entries}

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

    <!-- Contract: KIOSK-D-n handles routing; do not rename without explicit approval. -->
    <!-- Move kiosk display 1 windows to the configured output -->
    <windowRule identifier="*KIOSK-D-1*">
      <action name="MoveToOutput" output="\$display_1_output" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>

    <!-- Move kiosk display 1 windows to the configured output by title -->
    <windowRule title="*KIOSK-D-1*">
      <action name="MoveToOutput" output="\$display_1_output" />
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>
\${labwc_display_2_rules}

    <!-- Contract: maximize is a separate matcher; preserve this two-step behavior. -->
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
XML
EOF
  step_ok
else
  step_error "Unable to write /home/$app_user/.local/bin/kiosk-sync-display-map"
fi
run_step "Setting runtime sync helper ownership" chown "$app_user:$app_user" "/home/$app_user/.local/bin/kiosk-sync-display-map"
run_step "Making runtime sync helper executable" chmod +x "/home/$app_user/.local/bin/kiosk-sync-display-map"
run_step "Rendering labwc rc.xml from display map" runuser -u "$app_user" -- "/home/$app_user/.local/bin/kiosk-sync-display-map"
# Create a zero-size labwc theme so even if SSD is applied it renders invisibly
run_step "Setting ownership for labwc config" chown "$app_user:$app_user" "/home/$app_user/.config/labwc/rc.xml"
run_step "Creating kiosk theme directory" su "$app_user" -c "mkdir -p ~/.local/share/themes/kiosk/openbox-3"
step_begin "Writing kiosk theme configuration"
if cat << 'EOF' > "/home/$app_user/.local/share/themes/kiosk/openbox-3/themerc"; then
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
if cat << EOF > "/home/$app_user/.config/labwc/autostart"; then
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
if cat << EOF > "/home/$app_user/.local/bin/kiosk"; then
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
DEFAULT_NUM_DISPLAYS="$kiosk_num_displays"
DEFAULT_DISPLAY_1_OUTPUT="$display_1_output"
DEFAULT_DISPLAY_2_OUTPUT="$display_2_output"
NUM_DISPLAYS="$DEFAULT_NUM_DISPLAYS"
DISPLAY_1_OUTPUT="$DEFAULT_DISPLAY_1_OUTPUT"
DISPLAY_2_OUTPUT="$DEFAULT_DISPLAY_2_OUTPUT"
DISPLAY_MAP_SYNC="\$HOME/.local/bin/kiosk-sync-display-map"
DISPLAY_MAP_ENV="\$XDG_RUNTIME_DIR/kiosk/display-map.env"
TARGET_WAYLAND_DISPLAY="wayland-0"

WAIT_SECS=20
APPLY_RETRIES=20
APPLY_RETRY_DELAY_SECS=0.5

log() { echo "kiosk: \$*"; }

load_runtime_display_map() {
  NUM_DISPLAYS="\$DEFAULT_NUM_DISPLAYS"
  DISPLAY_1_OUTPUT="\$DEFAULT_DISPLAY_1_OUTPUT"
  DISPLAY_2_OUTPUT="\$DEFAULT_DISPLAY_2_OUTPUT"

  if [ -x "\$DISPLAY_MAP_SYNC" ]; then
    if ! "\$DISPLAY_MAP_SYNC"; then
      log "Display map sync helper failed: \$DISPLAY_MAP_SYNC"
      return 1
    fi
  fi

  if [ -f "\$DISPLAY_MAP_ENV" ]; then
    # shellcheck disable=SC1090
    . "\$DISPLAY_MAP_ENV"
    if [ -n "\${KIOSK_NUM_DISPLAYS:-}" ]; then
      NUM_DISPLAYS="\$KIOSK_NUM_DISPLAYS"
    fi
    if [ -n "\${KIOSK_DISPLAY_1_OUTPUT:-}" ]; then
      DISPLAY_1_OUTPUT="\$KIOSK_DISPLAY_1_OUTPUT"
    fi
    if [ -n "\${KIOSK_DISPLAY_2_OUTPUT:-}" ]; then
      DISPLAY_2_OUTPUT="\$KIOSK_DISPLAY_2_OUTPUT"
    fi
  fi

  if [ "\$NUM_DISPLAYS" != "1" ] && [ "\$NUM_DISPLAYS" != "2" ]; then
    NUM_DISPLAYS="\$DEFAULT_NUM_DISPLAYS"
  fi

  if [ "\$NUM_DISPLAYS" = "1" ]; then
    DISPLAY_2_OUTPUT=""
  fi

  return 0
}

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

output_exists() {
  local output="\$1"
  wayland_query | awk -v output="\$output" '\$1 == output { found=1; exit } END { exit(found ? 0 : 1) }'
}

resolve_output_name() {
  local preferred="\$1"
  local alternate=""

  if output_exists "\$preferred"; then
    printf '%s' "\$preferred"
    return 0
  fi

  case "\$preferred" in
    HDMI-A-*) alternate="HDMI-\${preferred#HDMI-A-}" ;;
    HDMI-*) alternate="HDMI-A-\${preferred#HDMI-}" ;;
  esac

  if [ -n "\$alternate" ] && output_exists "\$alternate"; then
    printf '%s' "\$alternate"
    return 0
  fi

  return 1
}

current_output_width() {
  local output="\$1"
  wayland_query | awk -v output="\$output" '
    \$1 == output { in_output=1; next }
    /^[^[:space:]]/ { in_output=0 }
    in_output && /current/ {
      for (i = 1; i <= NF; i++) {
        if (\$i ~ /^[0-9]+x[0-9]+\$/) {
          split(\$i, dims, "x")
          print dims[1]
          exit
        }
      }
    }
  '
}

output_supports_forced_mode() {
  local output="\$1"
  case "\$output" in
    HDMI-A-*|HDMI-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

enable_output_at_pos() {
  local output="\$1"
  local pos="\$2"

  if [ "\$FORCE_MODE" -eq 1 ] && output_supports_forced_mode "\$output"; then
    wlr-randr --output "\$output" --on --mode "\$MODE" --pos "\$pos"
  else
    wlr-randr --output "\$output" --on --pos "\$pos"
  fi
}

effective_output_width() {
  local output="\$1"

  if [ "\$FORCE_MODE" -eq 1 ] && output_supports_forced_mode "\$output"; then
    printf '%s' "\${MODE%%x*}"
    return 0
  fi

  current_output_width "\$output"
}

start_kiosk_target() {
  log "Layout applied successfully."
  export WAYLAND_DISPLAY="\$TARGET_WAYLAND_DISPLAY"
  systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP GTK_THEME || true
  systemctl --user stop kiosk.target || true
  sleep 1
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

  local out1 out2
  out1="\$(resolve_output_name "\$DISPLAY_1_OUTPUT" || true)"
  out2=""
  if [ "\$NUM_DISPLAYS" -eq 2 ]; then
    out2="\$(resolve_output_name "\$DISPLAY_2_OUTPUT" || true)"
  fi

  if [ -z "\${out1:-}" ]; then
    log "Could not find configured primary output '\$DISPLAY_1_OUTPUT' via wlr-randr. Full output state:"
    wayland_query || true
    return 1
  fi

  if [ "\$NUM_DISPLAYS" -eq 2 ] && [ -z "\${out2:-}" ]; then
    log "Could not find configured second output '\$DISPLAY_2_OUTPUT' via wlr-randr. Full output state:"
    wayland_query || true
    return 1
  fi

  for _ in \$(seq 1 "\$APPLY_RETRIES"); do
    if [ "\$NUM_DISPLAYS" -eq 2 ]; then
      if enable_output_at_pos "\$out1" "0,0"; then
        out1_width="\$(effective_output_width "\$out1")"
        if [ -z "\$out1_width" ]; then
          log "Could not determine current width for \$out1 after enabling it."
        elif enable_output_at_pos "\$out2" "\${out1_width},0"; then
          start_kiosk_target
          return \$?
        fi
      fi
    else
      if enable_output_at_pos "\$out1" "0,0"; then
        start_kiosk_target
        return \$?
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

if ! load_runtime_display_map; then
  exit 1
fi

status_dir="\$XDG_RUNTIME_DIR/kiosk-status-\$\$"
init_status_file="\$status_dir/init.status"
labwc_status_file="\$status_dir/labwc.status"
init_pid=""
labwc_pid=""

cleanup_children() {
  [ -n "\$init_pid" ] && kill "\$init_pid" 2>/dev/null || true
  [ -n "\$labwc_pid" ] && kill "\$labwc_pid" 2>/dev/null || true
  [ -n "\$init_pid" ] && wait "\$init_pid" 2>/dev/null || true
  [ -n "\$labwc_pid" ] && wait "\$labwc_pid" 2>/dev/null || true
  pkill -TERM -x labwc 2>/dev/null || true
  sleep 0.5
  pkill -KILL -x labwc 2>/dev/null || true
  rm -rf "\$status_dir"
}

trap 'cleanup_children; exit 143' HUP INT TERM

mkdir -p "\$status_dir"

(
  set +e
  init_kiosk_after_wayland_ready
  printf '%s\n' "\$?" > "\$init_status_file"
) &
init_pid=\$!

(
  set +e
  dbus-run-session -- labwc
  printf '%s\n' "\$?" > "\$labwc_status_file"
) &
labwc_pid=\$!

while true; do
  if [ -f "\$init_status_file" ]; then
    init_status="\$(cat "\$init_status_file")"
    if [ "\$init_status" -ne 0 ]; then
      log "Kiosk initialization failed with status \$init_status; stopping labwc."
      kill "\$labwc_pid" 2>/dev/null || true
      wait "\$labwc_pid" 2>/dev/null || true
      rm -rf "\$status_dir"
      exit "\$init_status"
    fi

    log "Kiosk initialization completed successfully."
    if wait "\$labwc_pid"; then
      labwc_status=0
    else
      labwc_status=\$?
    fi
    rm -rf "\$status_dir"
    exit "\$labwc_status"
  fi

  if [ -f "\$labwc_status_file" ]; then
    labwc_status="\$(cat "\$labwc_status_file")"
    log "labwc exited with status \$labwc_status before kiosk initialization completed."
    kill "\$init_pid" 2>/dev/null || true
    wait "\$init_pid" 2>/dev/null || true
    rm -rf "\$status_dir"
    exit "\$labwc_status"
  fi

  sleep 0.2
done
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

  cat << EOF > "/home/$app_user/applications/kioskbrowser-${browser_num}/index.html" || return 1
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>KIOSK-D-${browser_num}</title>

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

  cat << EOF > "/home/$app_user/applications/kioskbrowser-${browser_num}/start.sh" || return 1
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
# Contract with labwc rules: keep both KIOSK-D-n and -Maximized tokens unless explicitly approved.
OUTPUT_NAME="KIOSK-D-${browser_num}-Maximized"

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

run_step "Generating browser 1 launcher" create_kioskbrowser_launcher 1
run_step "Generating browser 2 launcher" create_kioskbrowser_launcher 2

# add kiosk.service to start the graphical session on tty1 at boot
step_begin "Writing kiosk.service"
if cat << EOF > /etc/systemd/system/kiosk.service; then
[Unit]
Description=Kiosk graphical session on tty1
After=systemd-user-sessions.service systemd-logind.service seatd.service
Wants=systemd-user-sessions.service seatd.service

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
ExecStopPost=/bin/sh -c 'XDG_RUNTIME_DIR=/run/user/$app_uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$app_uid/bus systemctl --user stop kiosk.target || true; pkill -TERM -u $app_user -x labwc || true; sleep 1; pkill -KILL -u $app_user -x labwc || true'
Restart=on-failure
RestartSec=2
KillMode=control-group
TimeoutStopSec=5

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
  if cat << EOF > "/home/$app_user/.config/systemd/user/touchkeyboard.service"; then
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
  cat << EOF > "/home/$app_user/.config/systemd/user/kioskbrowser-${browser_num}.service" || return 1
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
if cat << EOF > "/home/$app_user/.config/systemd/user/kiosk.target"; then
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
if [ "$rpi_connect" -eq 1 ]; then
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
  print_line ""
  print_line "${C_BRIGHT_WHITE}    To choose which display Raspberry Pi Connect shares, run:${C_RESET}"
  print_line ""
  print_line "${C_WHITE}       wayvncctl --socket=/run/user/$app_uid/rpi-connect-wayvnc-ctl.sock output-set HDMI-A-1${C_RESET}"
  print_line ""
  print_line "${C_BRIGHT_WHITE}    The output can be set to HDMI-A-1, HDMI-A-2, DSI-1 or DSI-2. This setting is not persistent.${C_RESET}"
fi

# all done - countdown to reboot
cleanup_command_logs
trap - EXIT
if [ "$reboot" -eq 1 ]; then
  print_line ""
  for i in $(seq 30 -1 1) ; do echo -ne "\r${C_BRIGHT_RED}*** Rebooting in $i seconds.  (CTRL-C to cancel) ***${C_RESET}" ; sleep 1 ; done
  print_line ""
  run_step "Rebooting system" reboot
else
  print_line ""
  print_line "${C_YELLOW}*** A reboot is strongly suggested before using the kiosk setup.  Run: sudo reboot${C_RESET}"
  print_line ""
fi
