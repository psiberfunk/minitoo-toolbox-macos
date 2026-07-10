# Divoom MiniToo macOS Daemon

Tools for sending images, GIFs, and short videos to a **Divoom MiniToo** over Bluetooth Classic RFCOMM from macOS.

The core of this repo is a Swift daemon that keeps the Divoom app channel open, plus a small macOS menu-bar app and Python media conversion tooling.

> `omo-slim/` contains local working media/assets and is not the main project API. The reusable project is the daemon, menu-bar app, CLI, and protocol notes.

## What this does

- Opens the Divoom MiniToo app protocol over Bluetooth RFCOMM channel `1`.
- Avoids repeated macOS Bluetooth audio reconnect/disconnect by keeping one daemon connection open.
- Converts PNG/JPEG/GIF/MP4/video into the Divoom animation payload format.
- Sends jobs through a localhost daemon at `127.0.0.1:40583`.
- Provides a copyable macOS `.app` that starts the daemon from the menu bar.

## Device assumptions

```text
RFCOMM channel: 1
Daemon port:    40583
```

The device's Bluetooth MAC address is **not** hardcoded — see "First-time setup" below for how the app finds and remembers it.

## First-time setup

The menu-bar app doesn't ship with any device's MAC address baked in. The first time it launches with no address cached yet, it opens a **"Set Up MiniToo"** window instead of starting the daemon:

1. Power on the MiniToo and make sure it isn't currently connected to a phone/tablet (a Bluetooth Classic device generally only holds one active connection at a time).
2. Click **Scan for Devices**. This runs a short native Bluetooth inquiry and
   separately lists saved pairing records. Nearby devices are labeled
   **Nearby**; saved records are not evidence that a device is currently in
   range. If Bluetooth is off, the app asks you to turn it on first.
3. Click **Use This Device** next to the right entry. If the device isn't already paired, this triggers pairing; macOS may show its own native pairing prompt the first time.
4. The address is cached (`UserDefaults`) and used for every future launch — you won't see this window again unless you use "Change Device…".

To change devices later, or to fix a wrong auto-detected address, open **Preferences… (⌘,)** — the "Device" section shows the currently cached address and has a **Change Device…** button that reopens the same scan flow.

**Advanced / scripting:** you can skip the scan UI entirely and set the address directly:

- Pass `--address XX:XX:XX:XX:XX:XX` as a launch argument to the app itself (re-caches it on that launch, then behaves normally).
- The standalone CLI tools (`tools/divoom-daemon`, and the raw dev tools `DivoomRFCOMM`/`DivoomRFCOMMSend`) all take the address as their first positional argument — there's no default, so it must always be passed explicitly:
  ```bash
  tools/divoom-daemon B1:21:81:6F:4D:F0 1 40583
  ```

If you don't know your device's MAC and don't want to use the in-app scan,
macOS Bluetooth Settings can display nearby and saved devices by name.

## Requirements

- macOS
- Xcode Command Line Tools / Swift compiler

For development CLI use:

- Python virtualenv with `Pillow`, `zstandard`, and `pyserial`
- `ffmpeg` for GIF/video input

Release builds freeze the menu-bar app's Python helpers into native executables,
so normal app usage does not need Python or a virtualenv installed. Local
development builds fall back to the repo `.venv` when frozen helpers are not
present.

The app uses macOS's native IOBluetooth framework for scan, pairing, audio
connection management, and RFCOMM. No Homebrew tools are required at runtime.
Release builds also bundle an LGPL-only FFmpeg executable for video input.

## Build the macOS app

```bash
tools/build-divoom-app.sh
```

To build both Swift slices on a Mac with the matching SDK support:

```bash
DIVOOM_ARCHS="arm64 x86_64" tools/build-divoom-app.sh
```

The `personal` branch's GitHub Actions workflow builds the two slices on
their native runners and publishes one universal ZIP to the rolling
`personal-latest` prerelease.

This builds:

```text
build/Divoom MiniToo.app
```

Install it:

```bash
cp -R "build/Divoom MiniToo.app" /Applications/
open "/Applications/Divoom MiniToo.app"
```

On launch, the app:

1. Disconnects the Divoom macOS audio profile once using native IOBluetooth.
2. Starts the Swift RFCOMM daemon.
3. Keeps the daemon available from the menu bar.

## Installing a release build

Download and unzip `Divoom-MiniToo-macos-universal.zip`, then drag **Divoom
MiniToo.app** into Applications. Releases are currently ad-hoc signed and not
notarized. On the first launch, macOS may block it; Control-click the app,
choose **Open**, then confirm **Open** in the dialog. Bluetooth permission is
requested by macOS when needed.

The accompanying FFmpeg source archive and [third-party notices](THIRD_PARTY_NOTICES.md)
are included for the bundled video converter.

Logs and generated packet artifacts are written under:

```text
~/Library/Application Support/DivoomMiniToo/
```

The app icon lives at `assets/AppIcon.icns` and is copied into the bundle
by the build script (`CFBundleIconFile` in `Info.plist`). Source art is
`assets/AppIcon-source.png` — bold, high-contrast line art with a solid
black glyph works far better than fine detail once scaled down to 16-32pt
(thin outlines and busy detail disappear at that size; a solid dark shape
is what actually survives). The content is centered on the 1024x1024
canvas filling ~90% of the frame — margin much wider than that measurably
hurts legibility at small sizes without buying anything back.

To regenerate after changing the source art:

```bash
python3 -c "
from PIL import Image
content = Image.open('assets/AppIcon-source.png').convert('RGB')
cw, ch = content.size
canvas = 1024
target_h = int(canvas * 0.90)          # tune this fill ratio if needed
scale = target_h / ch
target_w = int(cw * scale)
resized = content.resize((target_w, target_h), Image.LANCZOS)
square = Image.new('RGB', (canvas, canvas), 'white')
square.paste(resized, ((canvas - target_w)//2, (canvas - target_h)//2))
square.save('/tmp/icon.png')
"
mkdir -p /tmp/AppIcon.iconset
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" \
            "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" \
            "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  sips -z "${spec%%:*}" "${spec%%:*}" -s format png /tmp/icon.png --out "/tmp/AppIcon.iconset/${spec##*:}"
done
iconutil -c icns /tmp/AppIcon.iconset -o assets/AppIcon.icns
```

(`AppIcon-source.png` should already be a tightly-trimmed, white-background
image with no extra margin baked in — the script above adds all the
margin. `iconutil` also requires the input directory to literally be named
`*.iconset`, not just any folder — it fails silently with "Invalid
Iconset" otherwise.)

## Menu-bar app

The menu-bar title indicates daemon state:

```text
◇ Divoom = daemon stopped
◆ Divoom = daemon running
```

Useful actions:

- **Send Image/GIF/Video…** — choose a media file and send it.
- **Disconnect Audio + Start Daemon** — use when macOS audio owns the Bluetooth connection.
- **Restart Daemon** — stop, disconnect audio, and reopen RFCOMM.
- **Open Menu Log / Open Daemon Log** — inspect failures.

## CLI usage

Start the daemon manually:

```bash
tools/divoom-daemon B1:21:81:B1:F0:84 1 40583
```

Send media through the daemon:

```bash
.venv/bin/python tools/divoom_send.py path/to/image.png
.venv/bin/python tools/divoom_send.py path/to/animation.gif
.venv/bin/python tools/divoom_send.py path/to/video.mp4
```

Recommended compact video/GIF profile:

```bash
.venv/bin/python tools/divoom_send.py path/to/animation.gif \
  --size 128 \
  --fps 8 \
  --speed 125 \
  --max-frames 24 \
  --posterize-bits 4
```

Build packet files without sending:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --build-only
```

Ask the daemon to parse but not send:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --daemon-dry-run
```

## Integration API

For most integrations, call `divoom_send.py` as a subprocess. It is the media-level API:

```text
image/GIF/video -> Divoom packets -> daemon -> Bluetooth
```

Example:

```bash
"/Applications/Divoom MiniToo.app/Contents/Resources/.venv/bin/python" \
  "/Applications/Divoom MiniToo.app/Contents/Resources/tools/divoom_send.py" \
  "/absolute/path/to/file.gif" \
  --size 128 --fps 8 --speed 125 --max-frames 24 --posterize-bits 4
```

The daemon itself is packet-level. It listens on:

```text
127.0.0.1:40583
```

It accepts JSON pointing to a prebuilt length-prefixed packet file:

```json
{
  "packets": "/absolute/path/to/file-packets-lenpref.bin",
  "delay": 0.012,
  "dryRun": false
}
```

Python example:

```python
import json
import socket

req = {
    "packets": "/absolute/path/to/file-packets-lenpref.bin",
    "delay": 0.012,
    "dryRun": False,
}

with socket.create_connection(("127.0.0.1", 40583), timeout=10) as s:
    s.sendall(json.dumps(req).encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    print(s.recv(65536).decode())
```

Typical success response:

```json
{"ok":true,"message":"sent","packets":457,"bytes":122949,"sawRequest":true,"sawAck":true}
```

## Protocol notes

Full reverse-engineering notes are in [`PROTOCOL.md`](PROTOCOL.md).

High-level transport:

```text
01 <declared_len_le16> <cmd> <body...> <checksum_le16> 02
```

Animation/photo command:

```text
0x8b = SPP_APP_NEW_GIF_CMD2020
```

Media payloads are RGB888 frames compressed with Zstandard and wrapped in Divoom `0x8b` start/chunk packets.

Important finding:

```text
zstd window_log=17
```

This matches Android captures and avoids black/glitched output seen with larger zstd windows.

## Repository layout

```text
PROTOCOL.md                  Reverse-engineering and validation notes
tools/DivoomDaemon.swift     Swift RFCOMM daemon
tools/DivoomMenuBar.swift    macOS menu-bar controller
tools/divoom_send.py         Preferred media send CLI
tools/send_divoom_image.py   Image/GIF/video conversion + packet builder
tools/divoom_clock.py        Custom face selection helper
tools/build-divoom-app.sh    Builds packaged macOS app
assets/AppIcon.icns          App bundle icon (built into every .app by build-divoom-app.sh)
assets/AppIcon-source.jpg    Source artwork the icon was generated from
omo-slim/                    Local test/media assets; not core project API
```

## Troubleshooting

If daemon start fails with an RFCOMM error, use the app's **Disconnect Audio +
Start Daemon** action, then restart the daemon.

If a send reports `sent but final ACK not observed`, the device may still have updated successfully. This is usually an ACK-observation issue, not necessarily a failed transfer.

If video/GIF transfer is too slow, reduce frames before reducing pixels:

```bash
--size 128 --fps 6 --speed 167 --max-frames 18 --posterize-bits 4
```

Keep `--zstd-window-log 17` unless deliberately testing protocol behavior.

Hearing two Bluetooth connect chimes when the daemon starts is cosmetic: RFCOMM connects first, then macOS separately auto-restores the A2DP audio profile a couple seconds later. Not a bug.

After changing a setting under Control Center's "Device Settings" screen (notification sound, temperature unit, date format, clock format, Bluetooth auto-reconnect, remember-power-on-volume, auto power off), the MiniToo's own on-screen settings menu can keep showing the *old* value if you're already sitting on that menu when the change is sent. This is a MiniToo firmware quirk, not a bug in this app or a failed send — the setting takes effect immediately either way. Back out of that menu and go back in on the device to see it redraw with the current value.
