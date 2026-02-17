#!/bin/sh
# watchdog.sh — Keep keyremap alive across TV reboots
# Run on a host that's always on (e.g. Mac mini, Raspberry Pi, NAS)
# Crontab: */5 * * * * /bin/sh /path/to/watchdog.sh
#
# Config: edit the variables below

ADB="${ADB:-adb}"
TV="${TV:-192.168.1.209:5555}"
REMOTE_SCRIPT="/data/local/tmp/keyremap.sh"
LOCAL_SCRIPT=""  # Optional: path to local keyremap.sh to push on restart
LOGFILE="${WATCHDOG_LOG:-/tmp/tv-keyremap-watchdog.log}"
MAX_LOG_LINES=200

# ── Env vars to pass to keyremap.sh (optional overrides) ──
# KEYREMAP_DEVICE, KEYREMAP_SCANCODE_LE, KEYREMAP_TARGET, KEYREMAP_COOLDOWN

log() {
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOGFILE"
  lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n 100 "$LOGFILE" > "$LOGFILE.tmp"
    mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}

try_connect() {
  conn=$($ADB connect "$TV" 2>&1)
  case "$conn" in
    *"connected"*|*"already"*) return 0;;
  esac
  return 1
}

# Connect with retry
if ! try_connect; then
  $ADB kill-server >/dev/null 2>&1
  sleep 1
  $ADB start-server >/dev/null 2>&1
  if ! try_connect; then
    log "FAIL connect"
    exit 1
  fi
fi

if ! $ADB -s "$TV" shell echo ok >/dev/null 2>&1; then
  log "FAIL unreachable"
  exit 1
fi

# Check if keyremap is running (dd process reading from input device)
check=$($ADB -s "$TV" shell ps 2>/dev/null | grep "shell.*dd$" | tr -d '\r')
if [ -n "$check" ]; then
  exit 0  # Already running
fi

# Not running — restart
log "keyremap not running, starting..."

if [ -n "$LOCAL_SCRIPT" ] && [ -f "$LOCAL_SCRIPT" ]; then
  $ADB -s "$TV" push "$LOCAL_SCRIPT" "$REMOTE_SCRIPT" >/dev/null 2>&1
fi

$ADB -s "$TV" shell "rm -rf /data/local/tmp/keyremap.lock" >/dev/null 2>&1

# Build env prefix
ENV=""
[ -n "$KEYREMAP_DEVICE" ] && ENV="${ENV}KEYREMAP_DEVICE=$KEYREMAP_DEVICE "
[ -n "$KEYREMAP_SCANCODE_LE" ] && ENV="${ENV}KEYREMAP_SCANCODE_LE=$KEYREMAP_SCANCODE_LE "
[ -n "$KEYREMAP_TARGET" ] && ENV="${ENV}KEYREMAP_TARGET=$KEYREMAP_TARGET "
[ -n "$KEYREMAP_COOLDOWN" ] && ENV="${ENV}KEYREMAP_COOLDOWN=$KEYREMAP_COOLDOWN "

$ADB -s "$TV" shell "${ENV}setsid sh $REMOTE_SCRIPT < /dev/null > /dev/null 2>&1 &" </dev/null >/dev/null 2>&1
sleep 3

verify=$($ADB -s "$TV" shell ps 2>/dev/null | grep "shell.*dd$" | tr -d '\r')
if [ -n "$verify" ]; then
  log "OK started"
else
  log "FAIL start"
fi
