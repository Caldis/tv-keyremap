#!/bin/sh
# switch.sh — Interactively switch the remapped app
# Usage: ./switch.sh [adb_target]

ADB="${ADB:-adb}"
TV="${1:-192.168.1.209:5555}"
CONF_PATH="/data/local/tmp/keyremap.conf"

# Helper: run adb shell without consuming stdin
# MSYS_NO_PATHCONV prevents Git Bash on Windows from mangling /paths
adb_sh() {
  MSYS_NO_PATHCONV=1 $ADB -s "$TV" shell "$@" < /dev/null 2>/dev/null
}

echo "=== tv-keyremap: Switch App ==="
echo ""

# Connect
MSYS_NO_PATHCONV=1 $ADB connect "$TV" < /dev/null >/dev/null 2>&1
if ! adb_sh echo ok >/dev/null; then
  echo "ERROR: Cannot reach $TV"
  exit 1
fi

# Show current config
echo "Current config:"
CURRENT=$(adb_sh cat "$CONF_PATH" | grep "^TARGET=" | sed 's/TARGET=//' | tr -d "\"'" | tr -d '\r')
if [ -n "$CURRENT" ]; then
  echo "  → $CURRENT"
else
  echo "  (not configured)"
fi
echo ""

# Get all launchable packages
echo "Fetching installed apps..."
echo ""

APPS=$(adb_sh pm list packages -3 | sed 's/package://' | tr -d '\r' | sort)

i=1
for pkg in $APPS; do
  # Get launcher activity
  ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
  if [ -z "$ACTIVITY" ]; then
    ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -1 | tr -d '\r')
  fi
  [ -z "$ACTIVITY" ] && continue

  # Mark current
  MARK="  "
  case "$CURRENT" in
    *"$pkg"*) MARK="→ " ;;
  esac

  echo "${MARK}[$i] $pkg"
  echo "      $ACTIVITY"
  eval "APP_$i=$pkg"
  eval "ACT_$i=$ACTIVITY"
  i=$((i + 1))
done

echo ""
echo "  [$i] (Enter a custom activity manually)"
eval "APP_$i=custom"
MAX=$i

echo ""
printf "Select app [1-$MAX]: "
read CHOICE

if [ -z "$CHOICE" ] || ! [ "$CHOICE" -ge 1 ] 2>/dev/null || ! [ "$CHOICE" -le "$MAX" ] 2>/dev/null; then
  echo "Invalid choice."
  exit 1
fi

eval "SELECTED_PKG=\$APP_$CHOICE"
eval "SELECTED_ACT=\$ACT_$CHOICE"

if [ "$SELECTED_PKG" = "custom" ]; then
  printf "Enter activity (e.g. com.example.app/.MainActivity): "
  read SELECTED_ACT
  if [ -z "$SELECTED_ACT" ]; then
    echo "No activity provided."
    exit 1
  fi
fi

echo ""
echo "Selected: $SELECTED_ACT"

# Read existing config to preserve other settings
EXISTING_DEVICE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^DEVICE=" | sed 's/DEVICE=//' | tr -d '\r')
EXISTING_SCANCODE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^SCANCODE_LE=" | sed 's/SCANCODE_LE=//' | tr -d '\r')
EXISTING_COOLDOWN_VAL=$(adb_sh cat "$CONF_PATH" | grep "^COOLDOWN=" | sed 's/COOLDOWN=//' | tr -d '\r')

# Write config
# Write config via individual echo commands (more portable than piping)
adb_sh "chmod 666 $CONF_PATH 2>/dev/null; echo 'DEVICE=${EXISTING_DEVICE_VAL:-/dev/input/event3}' > $CONF_PATH"
adb_sh "echo 'SCANCODE_LE=${EXISTING_SCANCODE_VAL:-53050c00}' >> $CONF_PATH"
adb_sh "echo 'TARGET=$SELECTED_ACT' >> $CONF_PATH"
adb_sh "echo 'COOLDOWN=${EXISTING_COOLDOWN_VAL:-2}' >> $CONF_PATH"

echo ""
echo "Config updated:"
adb_sh cat "$CONF_PATH" | tr -d '\r'

# Check if daemon is running
RUNNING=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
if [ -n "$RUNNING" ]; then
  echo ""
  echo "Daemon is running — new config takes effect on next button press."
else
  echo ""
  echo "Daemon is not running."
  # Try to start it (may fail on Windows due to adb session lifecycle)
  adb_sh "rm -rf /data/local/tmp/keyremap.lock" >/dev/null
  MSYS_NO_PATHCONV=1 $ADB -s "$TV" shell "nohup setsid sh /data/local/tmp/keyremap.sh </dev/null >/dev/null 2>&1 &" </dev/null >/dev/null 2>&1 &
  ADBPID=$!
  sleep 4
  kill $ADBPID 2>/dev/null
  wait $ADBPID 2>/dev/null
  VERIFY_RUN=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
  if [ -n "$VERIFY_RUN" ]; then
    echo "Daemon started."
  else
    echo "Could not start daemon from this host."
    echo "The watchdog will auto-start it within 5 minutes, or start manually:"
    echo "  adb -s $TV shell \"setsid sh /data/local/tmp/keyremap.sh </dev/null >/dev/null 2>&1 &\""
  fi
fi

echo ""
echo "Done. Press the remapped button to test."
