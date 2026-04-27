#!/usr/bin/env bash
set -euo pipefail

# configure-vm-display.sh — Set resolution, enable fractional scaling, and
# configure scale on a running Tart Ubuntu desktop VM via the GNOME Mutter
# DBus API (Wayland).
#
# Usage:
#   bash configure-vm-display.sh <vm-name> [resolution] [scale]
#
# Examples:
#   bash configure-vm-display.sh pallewela-udesktop-2404
#   bash configure-vm-display.sh pallewela-udesktop-2404 2560x1600 1.25
#   bash configure-vm-display.sh pallewela-udesktop-2404 1920x1080 1.5
#
# Defaults:
#   resolution = 2560x1600
#   scale      = 1.25 (125%)
#
# Prerequisites:
#   - tart CLI installed
#   - VM is running with a GNOME Wayland session

VM_NAME="${1:-}"
RESOLUTION="${2:-2560x1600}"
SCALE="${3:-1.25}"

if [[ -z "$VM_NAME" ]]; then
  echo "Usage: bash configure-vm-display.sh <vm-name> [resolution] [scale]"
  exit 1
fi

# Validate VM is running
if ! tart list 2>/dev/null | awk -v n="$VM_NAME" '$2 == n { print $NF }' | grep -qx "running"; then
  echo "Error: VM '${VM_NAME}' is not running."
  echo "Start it first: tart run ${VM_NAME} &"
  exit 1
fi

# Environment needed to reach the user's GNOME session over tart exec
DBUS_ENV="export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus && export XDG_SESSION_TYPE=wayland"

run_in_guest() {
  tart exec "$VM_NAME" bash -c "${DBUS_ENV} && $1"
}

echo "==> Enabling fractional scaling..."
run_in_guest 'gsettings set org.gnome.mutter experimental-features "[\"scale-monitor-framebuffer\"]"'
echo "    gsettings set org.gnome.mutter experimental-features \"['scale-monitor-framebuffer']\""

echo "==> Verifying fractional scaling is enabled..."
FEATURES="$(run_in_guest 'gsettings get org.gnome.mutter experimental-features')"
echo "    experimental-features = ${FEATURES}"

echo "==> Querying current display config..."
DISPLAY_STATE="$(run_in_guest 'gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState')"
SERIAL="$(echo "$DISPLAY_STATE" | head -c 200 | sed -n 's/^(uint32 \([0-9]*\),.*/\1/p')"
echo "    config serial = ${SERIAL}"

# Find a matching mode for the requested resolution (pick highest refresh rate)
MODE="$(echo "$DISPLAY_STATE" | grep -o "'${RESOLUTION}@[0-9.]*'" | head -1 | tr -d "'")"

if [[ -z "$MODE" ]]; then
  echo "Error: No mode found matching resolution '${RESOLUTION}' on Virtual-1."
  echo "Available modes:"
  run_in_guest 'gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState' | grep -o "'[0-9]*x[0-9]*@[0-9.]*'" | tr -d "'" | sort -t'x' -k1 -rn | uniq
  exit 1
fi

# Extract refresh rate from mode string (e.g. "2560x1600@59.987" -> "59.987")
RATE="${MODE##*@}"
WIDTH="${RESOLUTION%%x*}"
HEIGHT="${RESOLUTION##*x}"

echo "==> Applying: mode=${MODE}, scale=${SCALE} (temporary — no confirmation dialog)..."
echo "    gdbus call ... ApplyMonitorsConfig ${SERIAL} 1 [(0,0,${SCALE},0,true,[('Virtual-1','${MODE}',{})])] []"

run_in_guest "gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig ${SERIAL} 1 \"[(0, 0, ${SCALE}, uint32 0, true, [('Virtual-1', '${MODE}', @a{sv} {})])]\" '[]'"

echo "==> Writing ~/.config/monitors.xml for persistence across reboots..."
run_in_guest "mkdir -p ~/.config && cat > ~/.config/monitors.xml << 'XMLEOF'
<monitors version=\"2\">
  <configuration>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>${SCALE}</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>Virtual-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>${WIDTH}</width>
          <height>${HEIGHT}</height>
          <rate>${RATE}</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
XMLEOF"
echo "    wrote ~/.config/monitors.xml (${WIDTH}x${HEIGHT}@${RATE}, scale=${SCALE})"

echo "==> Verifying..."
VERIFY_STATE="$(run_in_guest 'gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState')"
CURRENT_MODE="$(echo "$VERIFY_STATE" | grep -o "'${RESOLUTION}@[^}]*is-current[^}]*}" || true)"

if [[ -n "$CURRENT_MODE" ]]; then
  echo "    Resolution: ${RESOLUTION} — active"
  echo "    Scale: ${SCALE} ($(awk "BEGIN { printf \"%.0f%%\", ${SCALE} * 100 }"))"
  echo "    Fractional scaling: enabled"
  echo "==> Done."
else
  echo "    Warning: could not confirm the mode is active. Check the VM display."
fi
