#!/bin/sh
# test_switch.sh — Smoke tests for switch.sh --json envelope
# Mocks ADB and validates JSON output + exit codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; TOTAL=0

# --- Setup mock ADB ---
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/adb" << 'MOCK'
#!/bin/sh
# Mock ADB that returns canned responses
case "$*" in
  *connect*) echo "connected to 192.168.1.209:5555" ;;
  *"shell echo ok"*) echo "ok" ;;
  *"shell cat /data/local/tmp/keyremap.conf"*)
    printf 'DEVICE=/dev/input/event3\nSCANCODE_LE=53050c00\nTARGET=com.example.app/.MainActivity\nCOOLDOWN=2\n' ;;
  *"shell ps"*)
    echo "u0_a1  1234  1  12345 S shell dd" ;;
  *"shell ls /data/local/tmp/keyremap.sh"*)
    echo "/data/local/tmp/keyremap.sh" ;;
  *"shell pm list packages"*)
    printf 'package:com.example.app\npackage:com.test.tv\n' ;;
  *"dumpsys package com.example.app"*)
    echo "      com.example.app/.MainActivity filter"
    echo "        android.intent.category.LAUNCHER" ;;
  *"dumpsys package com.test.tv"*)
    echo "      com.test.tv/.TVActivity filter"
    echo "        android.intent.category.LEANBACK_LAUNCHER" ;;
  *"shell cat >"*)
    cat > /dev/null ;;  # consume stdin
  *) echo "mock: unhandled: $*" >&2 ;;
esac
MOCK
chmod +x "$MOCK_DIR/adb"

export ADB="$MOCK_DIR/adb"

# --- Test helpers ---
check() {
  _name="$1"; _expected_rc="$2"; shift 2
  TOTAL=$((TOTAL + 1))
  _out=$("$@" 2>/dev/null); _rc=$?
  _ok=true

  # Check exit code
  if [ "$_rc" != "$_expected_rc" ]; then
    echo "FAIL [$_name] exit code: expected=$_expected_rc got=$_rc"
    _ok=false
  fi

  # Validate JSON (must be non-empty for --json paths)
  if [ -z "$_out" ]; then
    echo "FAIL [$_name] empty output"
    _ok=false
  else
    if ! echo "$_out" | python -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      echo "FAIL [$_name] invalid JSON: $_out"
      _ok=false
    fi
    # Check envelope structure: must have ok, error, data
    _has_env=$(echo "$_out" | python -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'ok' in d and 'error' in d and 'data' in d else 'no')" 2>/dev/null)
    if [ "$_has_env" != "yes" ]; then
      echo "FAIL [$_name] missing envelope (ok/error/data): $_out"
      _ok=false
    fi
  fi

  if [ "$_ok" = true ]; then
    PASS=$((PASS + 1))
    echo "PASS [$_name]"
  else
    FAIL=$((FAIL + 1))
  fi
}

# --- Tests ---
check "status"        0  sh "$SCRIPT_DIR/switch.sh" --json status
check "current"       0  sh "$SCRIPT_DIR/switch.sh" --json current
check "list"          0  sh "$SCRIPT_DIR/switch.sh" --json list
check "set"           0  sh "$SCRIPT_DIR/switch.sh" --json set "com.example.app/.MainActivity"
check "missing-arg"   1  sh "$SCRIPT_DIR/switch.sh" --json set
check "no-subcommand" 1  sh "$SCRIPT_DIR/switch.sh" --json

# Test unreachable TV (mock adb that fails connect)
cat > "$MOCK_DIR/adb_fail" << 'FAILMOCK'
#!/bin/sh
case "$*" in
  *connect*) echo "failed" ;;
  *"shell echo ok"*) exit 1 ;;
  *) exit 1 ;;
esac
FAILMOCK
chmod +x "$MOCK_DIR/adb_fail"
ADB="$MOCK_DIR/adb_fail" check "connect-fail" 2 sh "$SCRIPT_DIR/switch.sh" --json status

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
