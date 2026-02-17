#!/bin/sh
# switch.sh — Switch the remapped app (interactive or via command)
#
# Usage:
#   ./switch.sh [--json] <command> [args] [adb_target]
#   ./switch.sh [adb_target]                  Interactive mode
#   ./switch.sh list [adb_target]             List available apps
#   ./switch.sh set <activity> [adb_target]   Set target directly
#   ./switch.sh current [adb_target]          Show current mapping
#   ./switch.sh status [adb_target]           Show full system state
#
# Exit codes:
#   0 — success
#   1 — invalid usage / bad arguments
#   2 — cannot connect to TV (ADB unreachable)
#   3 — not configured (no config file or no TARGET)
#   4 — daemon not running (status only, informational)
#   5 — config write failed

ADB="${ADB:-adb}"
CONF_PATH="/data/local/tmp/keyremap.conf"

# --- Parse --json flag ---
JSON=0
if [ "$1" = "--json" ]; then
  JSON=1; shift
fi

# --- Parse command ---
CMD=""
case "$1" in
  list|set|current|status) CMD="$1"; shift ;;
esac

if [ "$CMD" = "set" ]; then
  SET_TARGET="$1"; shift
  if [ -z "$SET_TARGET" ]; then
    if [ "$JSON" = 1 ]; then
      printf '{"error":"missing activity argument"}\n'
    else
      echo "Usage: switch.sh set <activity> [adb_target]"
      echo "  e.g. switch.sh set com.example.app/.MainActivity"
    fi
    exit 1
  fi
fi

TV="${1:-192.168.1.209:5555}"

# Helper: run adb shell without consuming stdin
# MSYS_NO_PATHCONV prevents Git Bash on Windows from mangling /paths
adb_sh() {
  MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" shell "$@" < /dev/null 2>/dev/null
}

# --- JSON helper ---
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr -d '\n\r'
}

# --- Connect ---
MSYS_NO_PATHCONV=1 "$ADB" connect "$TV" < /dev/null >/dev/null 2>&1
if ! adb_sh echo ok >/dev/null; then
  if [ "$JSON" = 1 ]; then
    printf '{"error":"cannot connect to TV","target":"%s"}\n' "$(json_escape "$TV")"
  else
    echo "ERROR: Cannot reach $TV"
  fi
  exit 2
fi

# --- Read current config ---
read_current() {
  adb_sh cat "$CONF_PATH" | grep "^TARGET=" | sed 's/TARGET=//' | tr -d "\"'" | tr -d '\r'
}

CURRENT=$(read_current)

# --- Command: status ---
if [ "$CMD" = "status" ]; then
  DAEMON_CHECK=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
  SCRIPT_CHECK=$(adb_sh "ls /data/local/tmp/keyremap.sh 2>/dev/null" | tr -d '\r')
  CONF_RAW=$(adb_sh cat "$CONF_PATH" 2>/dev/null | tr -d '\r')

  C_DEVICE=$(printf '%s' "$CONF_RAW" | grep "^DEVICE=" | sed 's/DEVICE=//')
  C_SCANCODE=$(printf '%s' "$CONF_RAW" | grep "^SCANCODE_LE=" | sed 's/SCANCODE_LE=//')
  C_TARGET=$(printf '%s' "$CONF_RAW" | grep "^TARGET=" | sed 's/TARGET=//')
  C_COOLDOWN=$(printf '%s' "$CONF_RAW" | grep "^COOLDOWN=" | sed 's/COOLDOWN=//')

  DAEMON_STATE="stopped"
  [ -n "$DAEMON_CHECK" ] && DAEMON_STATE="running"
  SCRIPT_INSTALLED=false
  [ -n "$SCRIPT_CHECK" ] && SCRIPT_INSTALLED=true

  if [ "$JSON" = 1 ]; then
    printf '{"connected":true,"daemon":"%s",' "$DAEMON_STATE"
    printf '"config":{"device":"%s",' "$(json_escape "$C_DEVICE")"
    printf '"scancode_le":"%s",' "$(json_escape "$C_SCANCODE")"
    printf '"target":"%s",' "$(json_escape "$C_TARGET")"
    printf '"cooldown":"%s"},' "$(json_escape "$C_COOLDOWN")"
    printf '"script_installed":%s}\n' "$SCRIPT_INSTALLED"
  else
    echo "=== tv-keyremap: Status ==="
    echo ""
    echo "Daemon:  $DAEMON_STATE"
    [ "$SCRIPT_INSTALLED" = true ] && echo "Script:  installed" || echo "Script:  not found"
    echo ""
    if [ -n "$CONF_RAW" ]; then
      echo "Config ($CONF_PATH):"
      printf '%s\n' "$CONF_RAW" | sed 's/^/  /'
    else
      echo "Config:  not found"
    fi
  fi

  [ -z "$CONF_RAW" ] || [ -z "$C_TARGET" ] && exit 3
  [ -z "$DAEMON_CHECK" ] && exit 4
  exit 0
fi

# --- Command: current ---
if [ "$CMD" = "current" ]; then
  if [ -n "$CURRENT" ]; then
    if [ "$JSON" = 1 ]; then
      printf '{"target":"%s"}\n' "$(json_escape "$CURRENT")"
    else
      echo "$CURRENT"
    fi
    exit 0
  else
    if [ "$JSON" = 1 ]; then
      printf '{"target":null}\n'
    else
      echo "(not configured)"
    fi
    exit 3
  fi
fi

# --- Command: list ---
list_apps() {
  APPS=$(adb_sh pm list packages -3 | sed 's/package://' | tr -d '\r' | sort)
  if [ "$JSON" = 1 ]; then
    printf '['
    FIRST=1
    for pkg in $APPS; do
      ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -n 1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
      [ -z "$ACTIVITY" ] && ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -n 1 | tr -d '\r')
      [ -z "$ACTIVITY" ] && continue
      IS_CURRENT=false
      case "$CURRENT" in *"$pkg"*) IS_CURRENT=true ;; esac
      [ "$FIRST" = 1 ] && FIRST=0 || printf ','
      printf '{"package":"%s","activity":"%s","current":%s}' \
        "$(json_escape "$pkg")" "$(json_escape "$ACTIVITY")" "$IS_CURRENT"
    done
    printf ']\n'
  else
    for pkg in $APPS; do
      ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -n 1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
      [ -z "$ACTIVITY" ] && ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -n 1 | tr -d '\r')
      [ -z "$ACTIVITY" ] && continue
      MARK="  "
      case "$CURRENT" in *"$pkg"*) MARK="→ " ;; esac
      echo "${MARK}${ACTIVITY}"
    done
  fi
}

if [ "$CMD" = "list" ]; then
  list_apps
  exit 0
fi

# --- Write config helper ---
# Validate that a value is safe for config (no shell metacharacters)
validate_config_val() {
  case "$1" in
    *[\'\"\`\$\;\&\|\>\<\(\)\{\}\!]*) return 1 ;;
    *) return 0 ;;
  esac
}

write_config() {
  TARGET_ACT="$1"
  if ! validate_config_val "$TARGET_ACT"; then
    return 1
  fi
  EXISTING_DEVICE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^DEVICE=" | sed 's/DEVICE=//' | tr -d '\r')
  EXISTING_SCANCODE_VAL=$(adb_sh cat "$CONF_PATH" | grep "^SCANCODE_LE=" | sed 's/SCANCODE_LE=//' | tr -d '\r')
  EXISTING_COOLDOWN_VAL=$(adb_sh cat "$CONF_PATH" | grep "^COOLDOWN=" | sed 's/COOLDOWN=//' | tr -d '\r')

  # Validate existing values before reuse
  validate_config_val "$EXISTING_DEVICE_VAL" || EXISTING_DEVICE_VAL=""
  validate_config_val "$EXISTING_SCANCODE_VAL" || EXISTING_SCANCODE_VAL=""
  validate_config_val "$EXISTING_COOLDOWN_VAL" || EXISTING_COOLDOWN_VAL=""

  # Write config atomically via stdin pipe (avoids shell interpolation on TV)
  printf 'DEVICE=%s\nSCANCODE_LE=%s\nTARGET=%s\nCOOLDOWN=%s\n' \
    "${EXISTING_DEVICE_VAL:-/dev/input/event3}" \
    "${EXISTING_SCANCODE_VAL:-53050c00}" \
    "$TARGET_ACT" \
    "${EXISTING_COOLDOWN_VAL:-2}" | \
    MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" shell "cat > $CONF_PATH" 2>/dev/null

  VERIFY=$(adb_sh cat "$CONF_PATH" | grep "^TARGET=" | sed 's/TARGET=//' | tr -d "\"'" | tr -d '\r')
  [ "$VERIFY" = "$TARGET_ACT" ]
}

check_daemon() {
  RUNNING=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
  if [ -n "$RUNNING" ]; then
    [ "$JSON" = 1 ] && echo "running" && return
    echo "Daemon is running — new config takes effect on next button press."
    return
  fi
  [ "$JSON" != 1 ] && echo "Daemon is not running."
  adb_sh "rm -rf /data/local/tmp/keyremap.lock" >/dev/null
  MSYS_NO_PATHCONV=1 "$ADB" -s "$TV" shell "nohup setsid sh /data/local/tmp/keyremap.sh </dev/null >/dev/null 2>&1 &" </dev/null >/dev/null 2>&1 &
  ADBPID=$!
  sleep 4
  kill $ADBPID 2>/dev/null
  wait $ADBPID 2>/dev/null
  VERIFY_RUN=$(adb_sh ps | grep "shell.*dd$" | tr -d '\r')
  if [ -n "$VERIFY_RUN" ]; then
    [ "$JSON" = 1 ] && echo "started" && return
    echo "Daemon started."
  else
    [ "$JSON" = 1 ] && echo "start_failed" && return
    echo "Could not start daemon from this host."
    echo "The watchdog will auto-start it within 5 minutes."
  fi
}

# --- Command: set ---
if [ "$CMD" = "set" ]; then
  if ! write_config "$SET_TARGET"; then
    if [ "$JSON" = 1 ]; then
      printf '{"ok":false,"error":"config write failed"}\n'
    else
      echo "ERROR: Failed to write config."
    fi
    exit 5
  fi
  if [ "$JSON" = 1 ]; then
    DAEMON_STATUS=$(check_daemon)
    printf '{"ok":true,"target":"%s","daemon":"%s"}\n' \
      "$(json_escape "$SET_TARGET")" "$DAEMON_STATUS"
  else
    echo "Config updated:"
    adb_sh cat "$CONF_PATH" | tr -d '\r'
    check_daemon
  fi
  exit 0
fi

# --- Interactive mode (no command) ---
if [ "$JSON" = 1 ]; then
  printf '{"error":"interactive mode not supported with --json, use a subcommand"}\n'
  exit 1
fi

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

MENU_TMP=$(mktemp)
trap 'rm -f "$MENU_TMP"' EXIT

i=1
for pkg in $APPS; do
  ACTIVITY=$(adb_sh "dumpsys package $pkg" | grep -B5 "LEANBACK_LAUNCHER\|android.intent.category.LAUNCHER" | grep "$pkg/" | head -n 1 | sed "s/.*\($pkg\/[^ ]*\).*/\1/" | tr -d ' \r')
  if [ -z "$ACTIVITY" ]; then
    ACTIVITY=$(adb_sh "cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $pkg" | tail -n 1 | tr -d '\r')
  fi
  [ -z "$ACTIVITY" ] && continue

  MARK="  "
  case "$CURRENT" in
    *"$pkg"*) MARK="→ " ;;
  esac

  echo "${MARK}[$i] $pkg"
  echo "      $ACTIVITY"
  echo "$ACTIVITY" >> "$MENU_TMP"
  i=$((i + 1))
done

echo ""
echo "  [$i] (Enter a custom activity manually)"
echo "custom" >> "$MENU_TMP"
MAX=$i

echo ""
printf "Select app [1-$MAX]: "
read CHOICE

if [ -z "$CHOICE" ] || ! [ "$CHOICE" -ge 1 ] 2>/dev/null || ! [ "$CHOICE" -le "$MAX" ] 2>/dev/null; then
  echo "Invalid choice."
  exit 1
fi

SELECTED_ACT=$(sed -n "${CHOICE}p" "$MENU_TMP")

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

if ! write_config "$SELECTED_ACT"; then
  echo "ERROR: Failed to write config."
  exit 5
fi

echo ""
echo "Config updated:"
adb_sh cat "$CONF_PATH" | tr -d '\r'
echo ""
check_daemon
echo ""
echo "Done. Press the remapped button to test."
