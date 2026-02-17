#!/bin/sh
# discover.sh — Find the scancode of a remote button
# Run from your PC/Mac: ./discover.sh [adb_target]
# Then press the button you want to remap.

ADB="${ADB:-adb}"
TV="${1:-192.168.1.209:5555}"
DURATION="${2:-30}"

echo "=== tv-keyremap: Button Scancode Discovery ==="
echo ""
echo "Connecting to $TV ..."
$ADB connect "$TV" >/dev/null 2>&1

if ! $ADB -s "$TV" shell echo ok >/dev/null 2>&1; then
  echo "ERROR: Cannot reach $TV"
  echo "Make sure ADB debugging is enabled on the TV."
  exit 1
fi

echo ""
echo "Available input devices:"
echo "────────────────────────"
$ADB -s "$TV" shell getevent -lp 2>/dev/null | grep -E "^add device|name:"
echo ""

# List devices for selection
DEVICES=$($ADB -s "$TV" shell getevent -lp 2>/dev/null | grep "^add device" | awk '{print $4}')
echo "Detected event devices:"
i=1
for d in $DEVICES; do
  NAME=$($ADB -s "$TV" shell getevent -lp 2>/dev/null | grep -A1 "^add device.*$d" | grep "name:" | sed 's/.*name:\s*//')
  echo "  [$i] $d  $NAME"
  i=$((i + 1))
done

echo ""
echo "Monitoring ALL devices for ${DURATION}s ..."
echo ">>> Press the button you want to remap NOW <<<"
echo ""

# Capture events to a temp file on the host
TMPFILE=$(mktemp)
timeout "$DURATION" $ADB -s "$TV" shell "getevent -lt" > "$TMPFILE" 2>/dev/null || true

if [ ! -s "$TMPFILE" ]; then
  echo "No events captured. Try pressing the button during the capture window."
  rm -f "$TMPFILE"
  exit 1
fi

echo ""
echo "=== Captured Events ==="
cat "$TMPFILE"
echo ""

# Extract EV_MSC MSC_SCAN lines
echo "=== Detected Scancodes ==="
grep "EV_MSC.*MSC_SCAN" "$TMPFILE" | awk '{print $NF}' | sort -u | while read sc; do
  # Convert to little-endian for keyremap.sh config
  # Input: 000c0553 → Output: 53050c00
  if [ ${#sc} -eq 8 ]; then
    LE="${sc:6:2}${sc:4:2}${sc:2:2}${sc:0:2}"
    echo "  Scancode: $sc  →  SCANCODE_LE=$LE"
  fi
done

echo ""
echo "=== Detected Key Events ==="
grep "EV_KEY" "$TMPFILE" | awk '{print $3, $4}' | sort -u | while read code dir; do
  echo "  Key: $code $dir"
done

# Find which device the events came from
echo ""
echo "=== Source Device ==="
LAST_DEV=""
while IFS= read -r line; do
  case "$line" in
    /dev/input/*) LAST_DEV=$(echo "$line" | awk '{print $1}' | tr -d ':') ;;
    *EV_MSC*MSC_SCAN*) echo "  Device: $LAST_DEV" ; break ;;
  esac
done < "$TMPFILE"

rm -f "$TMPFILE"

echo ""
echo "Done. Use the SCANCODE_LE value in keyremap.sh config."
echo "Use the device path as KEYREMAP_DEVICE."
