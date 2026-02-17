#!/bin/sh
# switch.sh — Switch the remapped app (interactive or via command)
#
# Usage:
#   ./switch.sh [adb_target]                  Interactive mode
#   ./switch.sh list [adb_target]             List available apps
#   ./switch.sh set <activity> [adb_target]   Set target directly
#   ./switch.sh current [adb_target]          Show current mapping

ADB="${ADB:-adb}"
CONF_PATH="/data/local/tmp/keyremap.conf"

# --- Parse command ---
CMD=""
case "$1" in
  list|set|current) CMD="$1"; shift ;;
esac

if [ "$CMD" = "set" ]; then
  SET_TARGET="$1"; shift
  if [ -z "$SET_TARGET" ]; then
    echo "Usage: switch.sh set <activity> [adb_target]"
    echo "  e.g. switch.sh set com.example.app/.MainActivity"
    exit 1
  fi
fi

TV="${1:-192.168.1.209:5555}"

# Helper: run adb shell without consuming stdin
# MSYS_NO_PATHCONV prevents Git Bash on Windows from mangling /paths
adb_sh() {
  MSYS_NO_PATHCONV=1 $ADB -s "$TV" shell "$@" < /dev/null 2>/dev/null
}

# --- Connect ---
MSYS_NO_PATHCONV=1 $ADB connect "$TV" < /dev/null >/dev/null 2>&1
if ! adb_sh echo ok >/dev/null; then
  echo "ERROR: Cannot reach $TV"
  exit 1
fi

# --- Read current config ---
read_current() {
  adb_sh cat "$CONF_PATH" | grep "^TARGET=" | sed 's/TARGET=//' | tr -d "\"'" | tr -d '\r'
}

CURRENT=$(read_current)

# --- Command: current ---
if [ "$CMD" = "current" ]; then
  if [ -n "$CURRENT" ]; then
    echo "$CURRENT"
  else
    echo "(not configured)"
    exit 1
  fi
  exit 0
fi

# --- Command: list ---
list_apps() {
  APPS=$(adb_sh pm list packages -3 | sed 's/package://' | tr -d '\r' | sort)
  for pkg in $APPS; do
    ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
    if [ -z "$ACTIVITY" ]; then
      ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -1 | tr -d '\r')
    fi
    [ -z "$ACTIVITY" ] && continue
    MARK="  "
    case "$CURRENT" in
      *"$pkg"*) MARK="→ " ;;
    esac
    echo "${MARK}${ACTIVITY}"
  done
}

if [ "$CMD" = "list" ]; then
  list_apps
  exit 0
fi

# --- Write config helper ---
write_config() {
  TARGET_ACT="$1"
  EXISTING_DEVICE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^DEVICE=" | sed 's/DEVICE=//' | tr -d '\r')
  EXISTING_SCANCODE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^SCANCODE_LE=" | sed 's/SCANCODE_LE=//' | tr -d '\r')
  EXISTING_COOLDOWN_VAL=$(adb_sh cat "$CONF_PATH" | grep "^COOLDOWN=" | sed 's/COOLDOWN=//' | tr -d '\r')

  adb_sh "chmod 666 $CONF_PATH 2>/dev/null; echo 'DEVICE=${EXISTING_DEVICE_VAL:-/dev/input/event3}' > $CONF_PATH"
  adb_sh "echo 'SCANCODE_LE=${EXISTING_SCANCODE_VAL:-53050c00}' >> $CONF_PATH"
  adb_sh "echo 'TARGET=$TARGET_ACT' >> $CONF_PATH"
  adb_sh "echo 'COOLDOWN=${EXISTING_COOLDOWN_VAL:-2}' >> $CONF_PATH"
}

check_daemon() {
  RUNNING=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
  if [ -n "$RUNNING" ]; then
    echo "Daemon is running — new config takes effect on next button press."
  else
    echo "Daemon is not running."
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
      echo "The watchdog will auto-start it within 5 minutes."
    fi
  fi
}

# --- Command: set ---
if [ "$CMD" = "set" ]; then
  write_config "$SET_TARGET"
  echo "Config updated:"
  adb_sh cat "$CONF_PATH" | tr -d '\r'
  check_daemon
  exit 0
fi

# --- Interactive mode (no command) ---
echo "=== tv-keyremap: Switch App ==="
echo ""

if [ -n "$CURRENT" ]; then
  echo "Current: $CURRENT"
else
  echo "Current: (not configured)"
fi
echo ""

echo "Fetching installed apps..."
echo ""

APPS=$(adb_sh pm list packages -3 | sed 's/package://' | tr -d '\r' | sort)

i=1
for pkg in $APPS; do
  ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
  if [ -z "$ACTIVITY" ]; then
    ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -1 | tr -d '\r')
  fi
  [ -z "$ACTIVITY" ] && continue

  MARK="  "
  case "$CURRENT" in
    *"$pkg"*) MARK="→ " ;;
  esac

  echo "${MARK}[$i] $pkg"
  echo "      $ACTIVITY"
  eval "ACT_$i=$ACTIVITY"
  i=$((i + 1))
done

echo ""
echo "  [$i] (Enter a custom activity manually)"
eval "ACT_$i=custom"
MAX=$i

echo ""
printf "Select app [1-$MAX]: "
read CHOICE

if [ -z "$CHOICE" ] || ! [ "$CHOICE" -ge 1 ] 2>/dev/null || ! [ "$CHOICE" -le "$MAX" ] 2>/dev/null; then
  echo "Invalid choice."
  exit 1
fi

eval "SELECTED_ACT=\$ACT_$CHOICE"

if [ "$SELECTED_ACT" = "custom" ]; then
  printf "Enter activity (e.g. com.example.app/.MainActivity): "
  read SELECTED_ACT
  if [ -z "$SELECTED_ACT" ]; then
    echo "No activity provided."
    exit 1
  fi
fi

echo ""
echo "Selected: $SELECTED_ACT"

write_config "$SELECTED_ACT"

echo ""
echo "Config updated:"
adb_sh cat "$CONF_PATH" | tr -d '\r'
echo ""
check_daemon
echo ""
echo "Done. Press the remapped button to test."
