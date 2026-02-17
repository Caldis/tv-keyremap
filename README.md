# tv-keyremap

Remap physical buttons on Android TV remotes to launch any app — no root required.

Works by reading raw Linux input events via `adb shell`, bypassing the system's hardcoded button-to-app mapping. Originally built to remap the [视频] (Video) button on Sony BRAVIA remotes, which is hardcoded to launch 华数TV.

## Compatibility

### What's Generic

The core mechanism — reading raw `input_event` structs from `/dev/input/eventN` — is standard Linux and works on **any Android TV** regardless of brand:

- `keyremap.sh` — pure POSIX shell, reads from Linux input subsystem
- `discover.sh` — uses `getevent`, available on all Android devices
- `watchdog.sh` — generic ADB keepalive

### What's Brand-Specific

When you remap a dedicated button (e.g. a streaming service shortcut), the original system handler still receives the key event and may show a toast or launch the original app. **Suppressing this behavior differs by brand:**

| Brand | System Handler | Suppression Method |
|-------|---------------|-------------------|
| Sony BRAVIA (China) | `com.sony.dtv.partnerkeycn` | `appops set ... TOAST_WINDOW deny` |
| Sony BRAVIA (Global) | `com.sony.dtv.partnerkey` | Same approach, untested |
| Xiaomi / Redmi TV | Varies | May need to disable via `pm disable-user` |
| Other brands | Varies | Use `discover.sh` to find the handler, then suppress |

If your TV has no system handler for the button (i.e. the button does nothing by default), you don't need any suppression — just deploy `keyremap.sh`.

### Tested On

| Device | Android | Arch | Remote | Button |
|--------|---------|------|--------|--------|
| Sony KD-85X9000H | 9 (API 28) | 32-bit ARM | SONY TV VRC 001 (BT) | [视频] → Bilibili |

> Contributions welcome — if you get it working on another device, please open a PR to update this table.

## How It Works

```
Physical Button Press
        │
        ▼
/dev/input/eventN ──► keyremap.sh (reads raw input_event structs via dd)
        │                    │
        ▼                    ▼
Android Input System    am start → Your App
        │
        ▼
Original handler (suppressed — see Brand-Specific section)
```

1. The daemon reads 16-byte `input_event` structs directly from the Linux input device
2. It matches `EV_MSC` / `MSC_SCAN` events against a target scancode
3. On match, it launches the configured app via `am start`
4. The original system handler still fires, but its side effects are suppressed

## Requirements

- Android TV with ADB debugging enabled (Settings → Developer Options → USB/Network debugging)
- ADB access from a PC, Mac, or Linux host
- The TV does **NOT** need root
- For persistence across reboots: a host that's always on (Mac mini, Raspberry Pi, NAS, etc.) to run the watchdog

## Quick Start

### 1. Discover Your Button's Scancode

```bash
# Connect to your TV
adb connect <TV_IP>:5555

# Run the discovery script — then press the button you want to remap
./discover.sh <TV_IP>:5555
```

Output:

```
=== Detected Scancodes ===
  Scancode: 000c0553  →  SCANCODE_LE=53050c00

=== Source Device ===
  Device: /dev/input/event3
```

Note down the `SCANCODE_LE` value and the device path.

### 2. Find Your Target App's Activity

```bash
# List installed apps
adb -s <TV_IP>:5555 shell pm list packages -3

# Find the launcher activity for your chosen app
adb -s <TV_IP>:5555 shell dumpsys package <package_name> | grep -B5 LEANBACK_LAUNCHER
```

The activity looks like: `com.example.app/.ui.MainActivity`

### 3. Install

```bash
./install.sh <TV_IP>:5555 <SCANCODE_LE> <TARGET_ACTIVITY>

# Example: remap Sony [视频] button to Bilibili
./install.sh 192.168.1.209:5555 53050c00 com.xiaodianshi.tv.yst/.ui.main.MainActivity
```

### 4. Suppress the Original Handler

See [Brand-Specific Notes](#brand-specific-notes) below for your TV brand.

### 5. Test

Press the remapped button. Your app should launch without any toast from the original handler.

## Switching Apps

After initial setup, you can switch the target app at any time without re-running the full install:

```bash
# Interactive mode — pick from a list
./switch.sh [TV_IP:5555]

# List available apps (non-interactive)
./switch.sh list [TV_IP:5555]

# Set target directly (non-interactive, automation-friendly)
./switch.sh set <activity> [TV_IP:5555]

# Show current mapping
./switch.sh current [TV_IP:5555]

# Show full system state (connection, daemon, config, script)
./switch.sh status [TV_IP:5555]
```

The config is stored at `/data/local/tmp/keyremap.conf` on the TV. The daemon re-reads it on each button press — no restart needed.

## Agent / Automation Interface

`switch.sh` supports a `--json` flag for structured output, making it usable by AI agents and scripts without regex parsing. All JSON responses use a unified envelope:

```bash
# JSON output for any subcommand
./switch.sh --json status
./switch.sh --json current
./switch.sh --json list
./switch.sh --json set <activity>
```

Example output (`--json status`):

```json
{
  "ok": true,
  "error": null,
  "data": {
    "connected": true,
    "daemon": "running",
    "config": {
      "device": "/dev/input/event3",
      "scancode_le": "53050c00",
      "target": "top.yogiczy.mytv.tv/.MainActivity",
      "cooldown": "2"
    },
    "script_installed": true
  }
}
```

### Exit Codes

All `switch.sh` commands use semantic exit codes:

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Invalid usage / bad arguments |
| `2` | Cannot connect to TV (ADB unreachable) |
| `3` | Not configured (no config file or no TARGET) |
| `4` | Daemon not running (status only, informational) |
| `5` | Config write failed |

### Project Manifest

`agent.json` at the repo root describes all commands, flags, exit codes, and config schema in a machine-readable format. Agents can read this file to discover available operations without parsing help text.

## Persistence (Surviving TV Reboots)

The keyremap daemon runs as a shell process on the TV. It will be killed when the TV reboots. To auto-restart it, use the watchdog script on an always-on host.

```bash
# Edit crontab on your always-on host
crontab -e

# Add (runs every 5 minutes):
*/5 * * * * TV=<TV_IP>:5555 /bin/sh /path/to/watchdog.sh
```

With custom config:

```bash
*/5 * * * * TV=192.168.1.209:5555 KEYREMAP_SCANCODE_LE=53050c00 KEYREMAP_TARGET=com.xiaodianshi.tv.yst/.ui.main.MainActivity /bin/sh /path/to/watchdog.sh
```

## Configuration

Config is stored on the TV at `/data/local/tmp/keyremap.conf`. The daemon re-reads it on each button press, so changes take effect immediately.

```ini
# /data/local/tmp/keyremap.conf
DEVICE=/dev/input/event3
SCANCODE_LE=53050c00
TARGET=com.xiaodianshi.tv.yst/.ui.main.MainActivity
COOLDOWN=2
```

You can also override via environment variables (useful for watchdog):

| Variable | Description |
|----------|-------------|
| `KEYREMAP_DEVICE` | Linux input device for the remote |
| `KEYREMAP_SCANCODE_LE` | Target scancode in little-endian hex |
| `KEYREMAP_TARGET` | App activity to launch |
| `KEYREMAP_COOLDOWN` | Minimum seconds between launches |

Priority: conf file > env vars > built-in defaults.

## Brand-Specific Notes

### Sony BRAVIA (China Region)

The `com.sony.dtv.partnerkeycn` system app intercepts dedicated remote buttons via `android.intent.action.GLOBAL_BUTTON` broadcast:

| Keycode | Button | Default App |
|---------|--------|-------------|
| 203 | [视频] | 华数TV / 腾讯视频 (depends on model variant) |
| 202 | [应用] | 当贝市场 |

The app mapping is hardcoded in the APK and cannot be changed without root. Solution:

```bash
# Suppress partnerkeycn's toast (persists across reboots)
adb -s $TV shell "cmd appops set com.sony.dtv.partnerkeycn TOAST_WINDOW deny"

# To undo:
adb -s $TV shell "cmd appops set com.sony.dtv.partnerkeycn TOAST_WINDOW allow"
```

The `install.sh` script does this automatically when it detects a Sony TV.

### Sony BRAVIA (Global)

Likely uses `com.sony.dtv.partnerkey` (without the `cn` suffix). The same `appops` approach should work — untested. If you verify this, please open a PR.

### Other Brands

General approach to find and suppress the original handler:

```bash
# 1. Find what handles the button press
adb shell "logcat -c && logcat -s ActivityManager:I"
# Press the button, look for which package launches

# 2. Find the broadcast receiver
adb shell "dumpsys package <package_name> | grep -A5 GLOBAL_BUTTON"

# 3. Try suppressing its toast
adb shell "cmd appops set <package_name> TOAST_WINDOW deny"

# 4. If that doesn't work, try disabling the package entirely
adb shell "pm disable-user --user 0 <package_name>"
# Note: this may cause a system "app disabled" toast on some Android versions
```

## Manual Operations

```bash
TV=192.168.1.209:5555

# Check if keyremap is running
adb -s $TV shell "ps | grep 'shell.*dd'"

# View logs
adb -s $TV shell cat /data/local/tmp/keyremap.log

# Stop keyremap
adb -s $TV shell "kill -9 $(adb -s $TV shell ps | grep 'shell.*dd' | awk '{print $2}')"

# Restart keyremap
adb -s $TV shell "rm -rf /data/local/tmp/keyremap.lock"
adb -s $TV shell "setsid sh /data/local/tmp/keyremap.sh < /dev/null > /dev/null 2>&1 &"
```

## Technical Details

### Why EV_MSC Instead of EV_KEY?

The daemon reads raw `input_event` structs using `dd` + `od`. Each button press generates 3 events: `EV_MSC` (scancode), `EV_KEY` (keycode), and `EV_SYN` (sync). Because `dd` + `od` shell processing is slow, the daemon often only catches the first event (`EV_MSC`). This is actually more reliable — the scancode is unique per physical button, while keycodes can be shared across buttons.

### 32-bit vs 64-bit

The `input_event` struct size depends on architecture:

| Architecture | Struct Size | timeval | type | code | value |
|-------------|-------------|---------|------|------|-------|
| 32-bit ARM | 16 bytes | 8B | 2B | 2B | 4B |
| 64-bit ARM | 24 bytes | 16B | 2B | 2B | 4B |

Check your TV's architecture:

```bash
adb shell getprop ro.product.cpu.abi
# armeabi-v7a → 32-bit (bs=16, default)
# arm64-v8a   → 64-bit (bs=24)
```

For 64-bit, change `bs=16` to `bs=24` in `keyremap.sh` and adjust the hex offsets:

```sh
# 64-bit offsets (8 extra bytes in timeval)
T="${CLEAN:32:4}"
C="${CLEAN:36:4}"
V="${CLEAN:40:8}"
```

## Files

| File | Runs On | Description |
|------|---------|-------------|
| `keyremap.sh` | Android TV (via adb) | Main remap daemon — generic, works on any Android TV |
| `switch.sh` | PC/Mac/Linux | Switch target app (interactive or via `set` command) |
| `discover.sh` | PC/Mac/Linux | Discover button scancodes |
| `install.sh` | PC/Mac/Linux | First-time deploy (auto-detects Sony partner key) |
| `watchdog.sh` | Always-on host | Auto-restart after TV reboot |
| `agent.json` | — | Machine-readable project manifest for AI agents |

## License

MIT
