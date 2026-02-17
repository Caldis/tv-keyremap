#!/bin/sh
# install.sh — Deploy keyremap to Android TV via ADB
# Usage: ./install.sh [adb_target] [scancode_le] [target_activity]

ADB="${ADB:-adb}"
TV="${1:-192.168.1.209:5555}"
SCANCODE_LE="${2:-}"
TARGET_ACTIVITY="${3:-}"
REMOTE_DIR="/data/local/tmp"

echo "=== tv-keyremap: Install ==="
echo ""

# Connect
$ADB connect "$TV" >/dev/null 2>&1
if ! $ADB -s "$TV" shell echo ok >/dev/null 2>&1; then
  echo "ERROR: Cannot reach $TV"
  exit 1
fi
echo "[✓] Connected to $TV"

# Discover scancode if not provided
if [ -z "$SCANCODE_LE" ]; then
  echo ""
  echo "No scancode provided. Run discover.sh first to find your button's scancode."
  echo "Usage: $0 <tv_ip:port> <scancode_le> <target_activity>"
  echo ""
  echo "Example:"
  echo "  $0 192.168.1.209:5555 53050c00 com.example.app/.MainActivity"
  exit 1
fi

# Discover target activity if not provided
if [ -z "$TARGET_ACTIVITY" ]; then
  echo ""
  echo "No target activity provided."
  echo "Usage: $0 <tv_ip:port> <scancode_le> <target_activity>"
  echo ""
  echo "Installed third-party apps:"
  $ADB -s "$TV" shell pm list packages -3 2>/dev/null | sed 's/package:/  /'
  exit 1
fi

# Find input device (use the first BT remote or fall back to event3)
DEVICE=$($ADB -s "$TV" shell "dumpsys input" 2>/dev/null | grep -B5 "KeyLayoutFile.*VRC\|KeyLayoutFile.*remote\|KeyLayoutFile.*bt_" | grep "Path:" | head -1 | awk '{print $2}')
if [ -z "$DEVICE" ]; then
  DEVICE="/dev/input/event3"
fi
echo "[✓] Input device: $DEVICE"

# Push keyremap.sh
$ADB -s "$TV" push keyremap.sh "$REMOTE_DIR/keyremap.sh" >/dev/null 2>&1
echo "[✓] Pushed keyremap.sh"

# Find the partner key package (Sony-specific)
PARTNERKEY=$($ADB -s "$TV" shell pm list packages 2>/dev/null | grep "partnerkey" | sed 's/package://')
if [ -n "$PARTNERKEY" ]; then
  echo "[i] Found partner key package: $PARTNERKEY"
  echo "    Suppressing its toast notifications..."
  $ADB -s "$TV" shell "cmd appops set $PARTNERKEY TOAST_WINDOW deny" 2>/dev/null
  echo "[✓] Toast suppressed for $PARTNERKEY"
fi

# Kill existing keyremap
$ADB -s "$TV" shell "rm -rf $REMOTE_DIR/keyremap.lock" >/dev/null 2>&1
for PID in $($ADB -s "$TV" shell ps 2>/dev/null | grep "shell.*dd$" | awk '{print $2}'); do
  $ADB -s "$TV" shell "kill -9 $PID" 2>/dev/null
done

# Start keyremap
$ADB -s "$TV" shell "KEYREMAP_DEVICE=$DEVICE KEYREMAP_SCANCODE_LE=$SCANCODE_LE KEYREMAP_TARGET=$TARGET_ACTIVITY setsid sh $REMOTE_DIR/keyremap.sh < /dev/null > /dev/null 2>&1 &" </dev/null >/dev/null 2>&1
sleep 3

# Verify
RUNNING=$($ADB -s "$TV" shell ps 2>/dev/null | grep "shell.*dd$")
if [ -n "$RUNNING" ]; then
  echo "[✓] keyremap is running"
else
  echo "[✗] keyremap failed to start"
  exit 1
fi

echo ""
echo "=== Install Complete ==="
echo "Press the remapped button to test."
echo ""
echo "To make this persistent across TV reboots, set up the watchdog."
echo "See watchdog.sh and README.md for details."
