# tv-keyremap

Remap physical buttons on Android TV remotes to launch any app — no root required.

Works by reading raw Linux input events via `adb shell`, bypassing the system's hardcoded button-to-app mapping. Originally built to remap the [视频] (Video) button on Sony BRAVIA remotes, which is hardcoded to launch a specific Chinese streaming app (华数TV).

## How It Works

```
Physical Button Press
        │
        ▼
/dev/input/eventN ──► keyremap.sh (reads raw input_event structs)
        │                    │
        ▼                    ▼
Android Input System    am start → Your App
        │
        ▼
Original handler (toast suppressed via appops)
```

1. The daemon reads 16-byte `input_event` structs directly from the Linux input device
2. It matches `EV_MSC` / `MSC_SCAN` events against a target scancode
3. On match, it launches the configured app via `am start`
4. The original system handler still fires, but its toast is suppressed via `appops`

## Requirements

- Android TV with ADB debugging enabled (Settings → Developer Options → USB/Network debugging)
- ADB access from a PC, Mac, or Linux host
- The TV does NOT need root
- For persistence across reboots: a host that's always on (Mac mini, Raspberry Pi, NAS, etc.) to run the watchdog

### Tested On

| Device | Android | Remote | Button |
|--------|---------|--------|--------|
| Sony KD-85X9000H | 9 (API 28) | SONY TV VRC 001 (BT) | [视频] → Bilibili |

Should work on any Android TV with ADB access. The scancode discovery process is generic.

## Quick Start

### 1. Discover Your Button's Scancode

```bash
# Connect to your TV
adb connect <TV_IP>:5555

# Run the discovery script — then press the button you want to remap
./discover.sh <TV_IP>:5555
```

The script will output something like:

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

# Example: remap to Bilibili
./install.sh 192.168.1.209:5555 53050c00 com.xiaodianshi.tv.yst/.ui.main.MainActivity
```

### 4. Test

Press the remapped button. Your app should launch.

## Persistence (Surviving TV Reboots)

The keyremap daemon runs as a shell process on the TV. It will be killed when the TV reboots. To auto-restart it, use the watchdog script on an always-on host.

### Crontab Setup

```bash
# Edit crontab on your always-on host
crontab -e

# Add (runs every 5 minutes):
*/5 * * * * TV=<TV_IP>:5555 /bin/sh /path/to/watchdog.sh
```

### Watchdog with Custom Config

```bash
# Via environment variables
*/5 * * * * TV=192.168.1.209:5555 KEYREMAP_SCANCODE_LE=53050c00 KEYREMAP_TARGET=com.xiaodianshi.tv.yst/.ui.main.MainActivity /bin/sh /path/to/watchdog.sh
```

## Configuration

All configuration is via environment variables (with defaults in `keyremap.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYREMAP_DEVICE` | `/dev/input/event3` | Linux input device for the remote |
| `KEYREMAP_SCANCODE_LE` | `53050c00` | Target scancode in little-endian hex |
| `KEYREMAP_TARGET` | `com.xiaodianshi.tv.yst/.ui.main.MainActivity` | App activity to launch |
| `KEYREMAP_COOLDOWN` | `2` | Minimum seconds between launches |

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

# Suppress toast for Sony partner key handler
adb -s $TV shell "cmd appops set com.sony.dtv.partnerkeycn TOAST_WINDOW deny"

# Restore toast (undo suppression)
adb -s $TV shell "cmd appops set com.sony.dtv.partnerkeycn TOAST_WINDOW allow"
```

## Technical Details

### Why EV_MSC Instead of EV_KEY?

The daemon reads raw `input_event` structs using `dd` + `od`. Each button press generates 3 events: `EV_MSC` (scancode), `EV_KEY` (keycode), and `EV_SYN` (sync). Because `dd` + `od` shell processing is slow, the daemon often only catches the first event (`EV_MSC`). This is actually more reliable — the scancode is unique per physical button, while keycodes can be shared across buttons.

### 32-bit vs 64-bit

The `input_event` struct size depends on architecture:
- 32-bit ARM: 16 bytes (8B timeval + 2B type + 2B code + 4B value)
- 64-bit ARM: 24 bytes (16B timeval + 2B type + 2B code + 4B value)

The current script assumes 32-bit (`bs=16`). If your TV runs 64-bit Android, change `bs=16` to `bs=24` and adjust the hex offsets in `keyremap.sh`:

```sh
# 64-bit: type at byte 16, code at byte 18, value at byte 20
T="${CLEAN:32:4}"
C="${CLEAN:36:4}"
V="${CLEAN:40:8}"
```

### Sony Partner Key System

On Sony BRAVIA TVs (China region), the `com.sony.dtv.partnerkeycn` system app handles dedicated remote buttons:
- Keycode 203 → [视频] button → launches VOD app (华数TV / 腾讯视频)
- Keycode 202 → [应用] button → launches Smart App (当贝市场)

The app mapping is hardcoded in the APK. Since we can't modify system apps without root, we suppress its toast via `appops` and let our daemon handle the button instead.

## Files

| File | Runs On | Description |
|------|---------|-------------|
| `keyremap.sh` | Android TV (via adb) | Main remap daemon |
| `discover.sh` | PC/Mac/Linux | Discover button scancodes |
| `install.sh` | PC/Mac/Linux | One-step deploy to TV |
| `watchdog.sh` | Always-on host | Auto-restart after TV reboot |

## License

MIT
