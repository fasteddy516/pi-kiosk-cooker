#!/bin/bash

# ensure the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "! This script must be run as root (i.e. with sudo)"
  exit
fi

# suppress interactive prompts from apt/dpkg for the duration of this script
export DEBIAN_FRONTEND=noninteractive

# set default reboot state if necessary
if [ ! -v reboot ]; then
  reboot=1
fi

# set default application username if it hasn't been specified
if [ ! -v app_user ]; then
  app_user=kiosk
fi

# set default edid if it hasn't been specified
if [ ! -v edid ]; then
  edid=none
fi

# set default number of displays if it hasn't been specified
if [ ! -v displays ]; then
  displays=1
fi

# set default Raspberry Pi Connect install state if it hasn't been specified
if [ ! -v rpi_connect ]; then
  rpi_connect=1
fi

# set default touch keyboard state if it hasn't been specified
if [ ! -v touch_keyboard ]; then
  touch_keyboard=1
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
    --no-touch-keyboard)
      touch_keyboard=0
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

# require a non-empty password to be explicitly provided
if [ -z "${app_password:-}" ]; then
  echo "! Missing required argument: --password=<password>"
  exit 1
fi

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
browser_package=""
for candidate in chromium-browser chromium; do
  candidate_version="$(apt-cache policy "$candidate" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [ -n "$candidate_version" ] && [ "$candidate_version" != "(none)" ]; then
    browser_package="$candidate"
    break
  fi
done
if [ -z "$browser_package" ]; then
  echo "! Unable to find a supported Chromium package (tried: chromium-browser, chromium)"
  exit 1
fi
echo "* Using browser package: $browser_package"

if [ $touch_keyboard -eq 1 ]; then
  squeekboard_version="$(apt-cache policy squeekboard 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [ -n "$squeekboard_version" ] && [ "$squeekboard_version" != "(none)" ]; then
    touch_keyboard_package="squeekboard"
    echo "* Using touch keyboard package: squeekboard"
  else
    touch_keyboard_package=""
    echo "! squeekboard not found in apt repos - touch keyboard will not be available"
  fi
else
  touch_keyboard_package=""
  echo "* Touch keyboard disabled via --no-touch-keyboard"
fi

kiosk_packages="labwc wlr-randr wayland-protocols xwayland dbus-user-session seatd $browser_package"
if [ -n "$touch_keyboard_package" ]; then
  kiosk_packages="$kiosk_packages $touch_keyboard_package"
fi
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

# set system-wide dark mode preference for GTK apps (including squeekboard)
su "$app_user" -c "gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'" 2>/dev/null || true
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
cat << 'EOF' > /home/$app_user/.config/labwc/rc.xml
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
    <!-- Belt-and-suspenders: disable SSD for every window regardless of app_id. -->
    <windowRule identifier="*" serverDecoration="no" />
  </windowRules>
</labwc_config>
EOF
chown $app_user:$app_user /home/$app_user/.config/labwc/rc.xml
# Create a zero-size labwc theme so even if SSD is applied it renders invisibly
su "$app_user" -c "mkdir -p ~/.local/share/themes/kiosk/openbox-3"
cat << 'EOF' > /home/$app_user/.local/share/themes/kiosk/openbox-3/themerc
border.width: 0
padding.width: 0
padding.height: 0
titlebar.height: 0
EOF
chown -R $app_user:$app_user /home/$app_user/.local/share/themes
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
export GTK_THEME=Adwaita:dark
export GTK_IM_MODULE=wayland
export QT_IM_MODULE=wayland
export SDL_IM_MODULE=wayland
export XMODIFIERS=@im=wayland

if [ ! -d "\$XDG_RUNTIME_DIR" ] || [ ! -w "\$XDG_RUNTIME_DIR" ]; then
  echo "session_start: XDG_RUNTIME_DIR '\$XDG_RUNTIME_DIR' is missing or not writable" >&2
  exit 1
fi

exec dbus-run-session -- labwc
EOF
chown $app_user:$app_user /home/$app_user/kiosk/session_start.sh
chmod +x /home/$app_user/kiosk/session_start.sh

# create local static app files and browser launchers
su "$app_user" -c "mkdir -p ~/kiosk/kiosk_browser_1/profile ~/kiosk/kiosk_browser_1/settings ~/kiosk/kiosk_browser_2/profile ~/kiosk/kiosk_browser_2/settings"
create_kiosk_browser_index() {
  local browser_num="$1"
  local settings_dir="~/kiosk/kiosk_browser_${browser_num}/settings"

  cat << EOF > /home/$app_user/kiosk/kiosk_browser_${browser_num}/index.html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kiosk Browser ${browser_num}</title>
  <style>
    :root {
      color-scheme: light;
      --bg-a: #f4f7ff;
      --bg-b: #d9e4ff;
      --ink: #12213d;
      --accent: #1f4fd1;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: "Noto Sans", "Segoe UI", sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at 20% 20%, #ffffff 0%, var(--bg-a) 45%, var(--bg-b) 100%);
    }

    main {
      width: min(90vw, 900px);
      padding: 3rem;
      border-radius: 1.2rem;
      background: rgba(255, 255, 255, 0.88);
      box-shadow: 0 1rem 3rem rgba(12, 40, 99, 0.2);
      text-align: center;
    }

    h1 {
      margin: 0;
      font-size: clamp(2rem, 5vw, 3.25rem);
      letter-spacing: 0.02em;
    }

    p {
      margin: 1rem 0 0;
      font-size: clamp(1rem, 2vw, 1.35rem);
      line-height: 1.5;
    }

    code {
      display: inline-block;
      margin-top: 1.5rem;
      padding: 0.5rem 0.75rem;
      border-radius: 0.5rem;
      color: #fff;
      background: var(--accent);
      font-size: 0.95rem;
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
      padding: 0.8rem 0.95rem;
      border: 1px solid #b6c6ef;
      border-radius: 0.65rem;
      font-size: 1rem;
      color: var(--ink);
      background: #ffffff;
    }

    button {
      border: 0;
      border-radius: 0.65rem;
      padding: 0.8rem 1rem;
      font-size: 1rem;
      font-weight: 600;
      color: #ffffff;
      background: var(--accent);
      cursor: pointer;
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
      color: #a21414;
    }

    #status.ok {
      color: #0f5b21;
    }

    @media (max-width: 700px) {
      .url-row {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <main>
    <h1>Kiosk Browser ${browser_num} Ready</h1>
    <p>This local startup page confirms the kiosk browser is running on display ${browser_num}.</p>
    <form id="set-start-page-form">
      <div class="url-row">
        <input id="start-url" type="text" inputmode="url" autocomplete="off" spellcheck="false" placeholder="https://example.com" aria-label="Start page URL">
        <button id="set-start-page" type="submit">Set start page</button>
      </div>
      <div id="status" aria-live="polite"></div>
    </form>
    <code>Enter the desired startup URL, press Set start page, then in the file picker open ${settings_dir} and press Open. To change it later, edit ${settings_dir}/startup_url.txt manually.</code>
  </main>

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

  chown $app_user:$app_user /home/$app_user/kiosk/kiosk_browser_${browser_num}/index.html
}

create_kiosk_browser_launcher() {
  local browser_num="$1"
  local output_name="$2"
  local fallback_window_pos="$3"
  local fallback_window_size="$4"

  cat << EOF > /home/$app_user/kiosk/kiosk_browser_${browser_num}/launch_kiosk_browser_${browser_num}.sh
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

APP_DIR="\$HOME/kiosk/kiosk_browser_${browser_num}"
PROFILE_DIR="\$APP_DIR/profile"
URL_FILE="\$APP_DIR/settings/startup_url.txt"
DEFAULT_URL="file://\$APP_DIR/index.html"
START_URL="\$DEFAULT_URL"
OUTPUT_NAME="${output_name}"
FALLBACK_WINDOW_POS="${fallback_window_pos}"
FALLBACK_WINDOW_SIZE="${fallback_window_size}"

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

get_output_position() {
  local output_name="\$1"
  local pos
  pos="\$(wlr-randr 2>/dev/null | awk -v out="\$output_name" '
    \$1 == out { in_out = 1; next }
    in_out && \$1 == "Position:" { print \$2; exit }
    in_out && /^[A-Za-z0-9_.-]+\$/ { in_out = 0 }
  ')"
  if [[ "\$pos" =~ ^[0-9]+,[0-9]+\$ ]]; then
    echo "\$pos"
    return 0
  fi
  return 1
}

get_output_size() {
  local output_name="\$1"
  local mode
  mode="\$(wlr-randr 2>/dev/null | awk -v out="\$output_name" '
    \$1 == out { in_out = 1; next }
    in_out && \$1 == "Current" && \$2 == "mode:" { print \$3; exit }
    in_out && /^[A-Za-z0-9_.-]+\$/ { in_out = 0 }
  ')"
  if [[ "\$mode" =~ ^[0-9]+x[0-9]+\$ ]]; then
    echo "\${mode/x/,}"
    return 0
  fi
  return 1
}

WINDOW_POS="\$FALLBACK_WINDOW_POS"
if resolved_pos="\$(get_output_position "\$OUTPUT_NAME")"; then
  WINDOW_POS="\$resolved_pos"
fi

WINDOW_SIZE="\$FALLBACK_WINDOW_SIZE"
if resolved_size="\$(get_output_size "\$OUTPUT_NAME")"; then
  WINDOW_SIZE="\$resolved_size"
fi

exec "\$BROWSER_BIN" \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform,VirtualKeyboard,WaylandWindowDecorations,WebContentsForceDark \
  --disable-features=Translate,MediaRouter,AutofillServerCommunication \
  --enable-wayland-ime \
  --enable-virtual-keyboard \
  --force-dark-mode \
  --touch-events=enabled \
  --app="\$START_URL" \
  --window-position="\$WINDOW_POS" \
  --window-size="\$WINDOW_SIZE" \
  --start-maximized \
  --no-first-run \
  --no-default-browser-check \
  --disable-session-crashed-bubble \
  --disable-infobars \
  --check-for-update-interval=31536000 \
  --user-data-dir="\$PROFILE_DIR"
EOF

  chown $app_user:$app_user /home/$app_user/kiosk/kiosk_browser_${browser_num}/launch_kiosk_browser_${browser_num}.sh
  chmod +x /home/$app_user/kiosk/kiosk_browser_${browser_num}/launch_kiosk_browser_${browser_num}.sh
}

create_kiosk_browser_index 1
create_kiosk_browser_index 2

create_kiosk_browser_launcher 1 "HDMI-A-1" "0,0" "1920,1080"
create_kiosk_browser_launcher 2 "HDMI-A-2" "1920,0" "1920,1080"

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

# create systemd service for the on-screen touch keyboard (if applicable)
if [ -n "$touch_keyboard_package" ]; then
  cat << EOF > /etc/systemd/system/kiosk-touch-keyboard.service
[Unit]
Description=Kiosk on-screen touch keyboard
Requires=kiosk-ui-init.service
After=kiosk-ui-init.service

[Service]
Type=simple
User=$app_user
Group=$app_user
Environment=HOME=/home/$app_user
Environment=GTK_THEME=Adwaita:dark
$wayland_client_env
ExecStart=/usr/bin/squeekboard
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
fi

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

create_kiosk_browser_service() {
  local browser_num="$1"
  cat << EOF > /etc/systemd/system/kiosk_browser_${browser_num}.service
[Unit]
Description=Kiosk browser on display $browser_num
Requires=kiosk-ui-init.service
After=kiosk-ui-init.service

[Service]
Type=simple
User=$app_user
Group=$app_user
WorkingDirectory=/home/$app_user
Environment=HOME=/home/$app_user
$wayland_client_env
ExecStart=/home/$app_user/kiosk/kiosk_browser_${browser_num}/launch_kiosk_browser_${browser_num}.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

# create browser services for display 1 and display 2
create_kiosk_browser_service 1
create_kiosk_browser_service 2

# finish setting up systemd services and targets
systemctl daemon-reload
systemctl enable kiosk-session.service
systemctl enable kiosk-session-ready.service
systemctl enable kiosk-ui-init.service
if [ -n "$touch_keyboard_package" ]; then
  systemctl enable kiosk-touch-keyboard.service
else
  systemctl disable --now kiosk-touch-keyboard.service >/dev/null 2>&1 || true
fi
systemctl enable kiosk_browser_1.service
if [ "$displays" -eq 2 ]; then
  systemctl enable kiosk_browser_2.service
else
  systemctl disable --now kiosk_browser_2.service >/dev/null 2>&1 || true
fi

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
