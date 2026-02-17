#!/system/bin/sh
# tv-keyremap — Android TV remote button remap daemon
# Runs on the TV via `adb shell`, monitors raw input events
# and launches a custom app when the target button is pressed.
#
# Config is read from /data/local/tmp/keyremap.conf on each button press,
# so you can switch apps without restarting the daemon.

# ── Defaults (overridden by conf file or env vars) ────────
DEVICE="${KEYREMAP_DEVICE:-/dev/input/event3}"
SCANCODE_LE="${KEYREMAP_SCANCODE_LE:-53050c00}"
TARGET="${KEYREMAP_TARGET:-com.xiaodianshi.tv.yst/.ui.main.MainActivity}"
COOLDOWN="${KEYREMAP_COOLDOWN:-2}"

# ── Runtime paths ─────────────────────────────────────────
CONFFILE="/data/local/tmp/keyremap.conf"
LOGFILE="/data/local/tmp/keyremap.log"
LOCKDIR="/data/local/tmp/keyremap.lock"
MAX_LOG_LINES=500

# ── Load config file (overrides defaults and env) ─────────
load_conf() {
  [ -f "$CONFFILE" ] && . "$CONFFILE"
}

load_conf

# ── Lock (single instance) ────────────────────────────────
mkdir "$LOCKDIR" 2>/dev/null || {
  OLD=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "Already running as PID $OLD"
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null
}
echo "$$" > "$LOCKDIR/pid"

log() {
  echo "[$(date)] $1" >> "$LOGFILE"
  lines=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n 200 "$LOGFILE" > "$LOGFILE.tmp"
    mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}

log "keyremap started PID=$$ device=$DEVICE scancode_le=$SCANCODE_LE target=$TARGET"

# ── Main loop ─────────────────────────────────────────────
# Reads raw 16-byte input_event structs (32-bit ARM):
#   bytes 0-7:   timeval (sec + usec)
#   bytes 8-9:   type   (uint16 LE)
#   bytes 10-11: code   (uint16 LE)
#   bytes 12-15: value  (int32  LE)
#
# Matches EV_MSC (type=0x0004) + MSC_SCAN (code=0x0004) + target scancode.

LAST=0
while true; do
  HEX=$(dd if="$DEVICE" bs=16 count=1 2>/dev/null | od -A n -t x1 2>/dev/null)
  CLEAN=$(echo "$HEX" | tr -d " \n\r\t")
  [ -z "$CLEAN" ] && { sleep 1; continue; }

  T="${CLEAN:16:4}"
  C="${CLEAN:20:4}"
  V="${CLEAN:24:8}"

  # EV_MSC=0400(LE) MSC_SCAN=0400(LE)
  if [ "$T" = "0400" ] && [ "$C" = "0400" ] && [ "$V" = "$SCANCODE_LE" ]; then
    NOW=$(date +%s)
    if [ $((NOW - LAST)) -ge $COOLDOWN ]; then
      LAST=$NOW
      # Re-read config to pick up app changes without restart
      load_conf
      am start -n "$TARGET" > /dev/null 2>&1
      log "launched $TARGET"
    fi
  fi
done

log "exited unexpectedly"
rm -rf "$LOCKDIR"
