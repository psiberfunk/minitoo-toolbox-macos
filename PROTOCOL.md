# Divoom MiniToo Bluetooth Photo Protocol

Notes from reversing the Divoom Android app + Android Bluetooth snoop captures, then validating sends from macOS.

## ⚠️ Safety: opcodes that brick the device until power-cycle

Cross-referenced from independent community reverse-engineering
([bugzmanov/divoom-minitoo](https://github.com/bugzmanov/divoom-minitoo))
and confirmed as real (if MiniToo-hostile) commands in a generic Divoom
device map ([d03n3rfr1tz3/hass-divoom](https://github.com/d03n3rfr1tz3/hass-divoom)):
sending these opcodes to a MiniToo puts it into a black-screen "sleep
monitoring" state that does **not** respond to any recovery command
(`Channel/OnOffScreen`, `Lyric/Enter`, `Photo/Enter`, `Channel/SetBrightness`,
game-exit, screen-ctrl) — only a **hardware power-cycle** recovers it.

**Never send:** `0x40` (set sleep auto off), `0xa3` (set sleep scene listen),
`0xa4` (set scene vol), `0xad` (set sleep color), `0xae` (set sleep light).

Do not probe this family further without a hardware power button within reach.

## Device / transport

- Device: `Divoom MiniToo-Audio`
- Bluetooth address used from macOS: `B1:21:81:B1:F0:84`
- Transport: Bluetooth Classic SPP over RFCOMM
- Working app protocol channel from macOS: RFCOMM channel `1`, opened directly via `IOBluetooth`.
- The macOS serial device `/dev/cu.DivoomMiniToo-Audio` exists, but was unreliable for this protocol. Direct RFCOMM worked.

SDP advertised services observed from macOS:

```text
JL_SPP  channel 10
JL_SPP  channel 1
SMS/MMS channel 17
JL_HFP  channel 4
```

Direct `IOBluetooth` findings:

- Channel `1` works for the Divoom app protocol when opened directly.
- Channel `10` was advertised but failed to open from macOS during testing.
- Channel `17` opened but is not the app protocol; it produced unrelated SMS/MMS-ish data.

## macOS connection learning

If the Divoom is connected as an audio device in macOS, opening the app RFCOMM path can fail or interact with the wrong profile.

Validated reliable flow:

```bash
blueutil --disconnect B1:21:81:B1:F0:84 || true
tools/divoom-rfcomm-send B1:21:81:B1:F0:84 1 <packets-lenpref.bin> 0.012
```

This avoids the noisy/visible audio profile and opens the RFCOMM app channel directly. The disconnect causes an audible reconnect/noise if audio was active, so the next goal is a daemon that opens RFCOMM once and keeps it open for multiple sends.

Preferred future UX:

- Start daemon once.
- Daemon opens RFCOMM channel `1` directly.
- Keep the channel open.
- Send multiple image jobs through the daemon without repeated disconnect/reconnect.

## Generic frame format

From decompiled Android method `com.divoom.Divoom.bluetooth.s.k()`:

```text
01 <declared_len_le16> <cmd> <body...> <checksum_le16> 02
```

Fields:

- `0x01`: start byte
- `declared_len`: `total_frame_len - 4`, little-endian uint16
  - Equivalent: `len(body) + 3`
- `cmd`: one-byte command
- `body`: command-specific bytes
- `checksum`: little-endian uint16
  - `sum(frame[1 : len(frame)-3]) & 0xffff`
- `0x02`: end byte

Python implementation:

```python
def frame(cmd: int, body: bytes = b"") -> bytes:
    out = bytearray(7 + len(body))
    out[0] = 0x01
    declared = len(out) - 4
    out[1:3] = declared.to_bytes(2, "little")
    out[3] = cmd & 0xFF
    out[4:4 + len(body)] = body
    checksum = sum(out[1:len(out) - 3]) & 0xFFFF
    out[-3:-1] = checksum.to_bytes(2, "little")
    out[-1] = 0x02
    return bytes(out)
```

## Photo / animation command

Command:

```text
0x8b = SPP_APP_NEW_GIF_CMD2020
```

From decompiled enum:

```java
SPP_APP_NEW_GIF_CMD2020(139)
```

### Start packet

Before chunks, send a start packet:

```text
cmd  = 0x8b
body = 00 <total_payload_len_le32>
```

Example from captured payload length `11937` (`0x2ea1`):

```hex
01 08 00 8b 00 a1 2e 00 00 ae 01 02
```

### Device request

The device asks for animation data with:

```hex
01 07 00 04 8b 55 00 01 ec 00 02
```

Interpretation from app logs/decompiled code:

- Outer command: `0x04`
- Extended/app command type: `0x8b`
- `bArr[6] == 0`: “device requests animation send”

The app then sends all chunks.

### Chunk packet

Each chunk uses command `0x8b`:

```text
cmd  = 0x8b
body = 01 <total_payload_len_le32> <seq_le16> <chunk_payload...>
```

Observed chunking:

- Full chunk payload: `256` bytes
- Full framed chunk length: `270` bytes
- Sequence starts at `0`
- Last chunk is shorter

Example first chunk prefix:

```hex
01 0a 01 8b 01 a1 2e 00 00 00 00 ...payload... checksum checksum 02
```

Decoded:

```text
01          start
0a 01       declared len = 266
8b          cmd
01          chunk marker
a1 2e 00 00 total payload len = 11937
00 00       seq = 0
...         256-byte chunk payload
```

### Final ACK

After a successful transfer, device replied:

```hex
01 09 00 04 bd 55 13 01 05 00 38 01 02
```

This matched Android capture and direct macOS sends.

## Encoded image payload

For the captured Android photo send, the reassembled payload began:

```hex
25 01 03 e8 08 08 00 00 2e 97 28 b5 2f fd ...
```

Layout from decompiled `W2.c.f()`:

```text
25                  format/type marker, decimal 37
01                  frame count / valid count
03 e8               speed, big-endian uint16; 1000 here
08                  row count
08                  column count
00 00 2e 97         compressed zstd length, big-endian uint32; 11927 here
28 b5 2f fd ...     Zstandard frame
```

Zstd details from the captured payload:

- Compressed length: `11927`
- Decompressed length: `49152`
- Raw pixel format: RGB888
- Dimensions: `128x128`
- `128 * 128 * 3 = 49152`

This was the size of one specific captured Android payload, not the panel's
actual resolution — see "Full panel resolution" below.

### Full panel resolution: 160x128, not 128x128

The physical panel is **160 wide x 128 tall**, confirmed on real hardware.
The row/column bytes in the header above are block counts in 16px units, not
raw pixel dimensions — `08 08` is 8x8 blocks (128x128px), simply using fewer
of the 10 available column-blocks than the panel has. Independent community
testing ([bugzmanov/divoom-minitoo](https://github.com/bugzmanov/divoom-minitoo))
confirmed 160x128 works over this same `0x8b` opcode using `08 0a` (8 row
blocks x 10 col blocks) with their JPEG-per-frame variant; we independently
confirmed the same asymmetric block count also works with our own
zstd-raw-RGB variant (marker `0x25` below), live on hardware.

Sending fewer columns than 160 does **not** letterbox or center — the
firmware paints only the claimed block region starting at the top-left, so
a square `128x128` send appears **left-justified** with the rightmost 32
columns left showing whatever was on screen before. This is expected
behavior of the block-addressing scheme, not a bug.

## Image conversion

Current sender behavior for arbitrary images:

1. EXIF transpose.
2. Convert to RGB.
3. Center-crop to the target aspect ratio (square by default, or the full
   160x128 panel aspect ratio with `--full-screen`).
4. Resize to the target dimensions (`128x128` by default, `160x128` with
   `--full-screen`).
5. Use raw RGB888 bytes.
6. Zstd-compress with level `17`.
7. Prefix encoded payload header:

```text
25 01 <speed_be16> <row_blocks> <col_blocks> <zstd_len_be32> <zstd_frame>
```

`row_blocks`/`col_blocks` are height/width in 16px units — `08 08` for the
default square `128x128`, `08 0a` for the full `160x128` panel via
`--full-screen`. Then wrap into `0x8b` start + chunks.

## GIF / video conversion

Android GIF/video sends use the same `0x8b` start/request/chunk transport. The encoded payload generalizes the still-image header:

```text
25 <frame_count_u8> <speed_ms_be16> <row_blocks_u8> <col_blocks_u8> <zstd_len_be32> <zstd_frame>
```

Where:

- `row_blocks` / `col_blocks` are 16-pixel blocks.
- Pixel dimensions are `col_blocks * 16` by `row_blocks * 16`.
- Decompressed bytes are concatenated RGB888 frames.
- Expected decompressed length is `frame_count * width * height * 3`.
- `frame_count` is one byte, so current tooling limits video/GIF sends to `<=255` frames.

MP4/video support in `tools/divoom_send.py` shells out to `ffmpeg` to sample frames, center-crop to the target aspect ratio (square by default, or 160x128 with `--full-screen`), resize, concatenate RGB888 frames, zstd-compress, and send through the same daemon path.

`--size` (still images and video alike) defaults to `128` — video used to default to `64` from before the zstd-window fix below existed, back when smaller video was the safer bet; that default was stale and has been corrected, since `128x128` (and now `160x128` via `--full-screen`) works fine for video too.

Example practical send:

```bash
.venv/bin/python tools/divoom_send.py input.mp4
```

Early MP4 tests falsely suggested a small raw-size limit because Python zstd's default window was too large. The key fix was matching Android's zstd window.

Critical zstd finding:

- Android's working high-frame payloads use a `128 KiB` zstd window (`window_log=17`).
- Python zstd's default can choose a larger window for multi-frame `128x128` video.
- With a larger window, the device may ACK the transfer but display black/glitched output.
- Current tooling defaults to `--zstd-window-log 17` to match Android captures.

Validated Android-style and macOS-generated sends:

- Resent captured Android payload `128x128`, `16` frames, `speed=75`, payload `5124` bytes: works/quality good.
- MP4-derived `128x128`, `4` frames, `speed=100`, `posterize-bits=4`, zstd window `17`: works/loops.
- MP4-derived `128x128`, `10` frames, `speed=100`, `posterize-bits=4`, zstd window `17`: works/looks good.
- MP4-derived `128x128`, `16` frames, `speed=75`, `posterize-bits=4`, zstd window `17`: works/looks best in early testing.
- MP4-derived `128x128`, `16` frames, `speed=75`, `posterize-bits=5`: works with better color but transfer is larger/slower.
- MP4-derived `128x128`, `26` frames, `speed=100`, `posterize-bits=4`: works/loops well.
- MP4-derived `128x128`, `26` frames, `speed=100`, `posterize-bits=5`: works but transfer feels too large/slow.
- MP4-derived `128x128`, `32` frames, `speed=100`, `posterize-bits=4`: works, but transfer time starts to feel less ideal.
- `48x48` / `3x3` blocks glitched in testing; stick to observed stable block sizes: `1x1`, `2x2`, `4x4`, `8x8` (`16`, `32`, `64`, `128` px).

Practical rules:

- Prefer `128x128` now that zstd `window_log=17` is fixed.
- Keep zstd window at `17`.
- Do not activate a custom face after upload unless you intentionally want to switch away from the uploaded animation; doing so can make the animation appear only briefly.
- Posterizing/noise reduction helps MP4-derived video compress more like phone GIFs. `posterize-bits=4` is fast/small; `posterize-bits=5` has better color but larger transfer.
- More frames increase both duration and transfer time. A good balance is around `20` frames at `100ms` (`~2s`).
- `--full-screen` (160x128, ~25% more pixels than 128x128) works for video/GIF too, hardware-confirmed; the profiles below were tuned at 128x128, so expect proportionally larger/slower transfers at full screen and adjust `--max-frames`/`--posterize-bits` down if needed.

Balanced recommended profile:

```bash
.venv/bin/python tools/divoom_send.py input.mp4 \
  --size 128 \
  --max-frames 20 \
  --fps 10 \
  --speed 100 \
  --posterize-bits 4
```

Higher-color shorter profile:

```bash
.venv/bin/python tools/divoom_send.py input.mp4 \
  --size 128 \
  --max-frames 16 \
  --fps 13.333 \
  --speed 75 \
  --posterize-bits 5
```

Longer-duration profile:

```bash
.venv/bin/python tools/divoom_send.py input.mp4 \
  --size 128 \
  --max-frames 26 \
  --fps 10 \
  --speed 100 \
  --posterize-bits 4
```

Build-only preview/packet generation:

```bash
.venv/bin/python tools/divoom_send.py input.mp4 --build-only
```

Full `128x128` video can generate large transfers; reduce `--max-frames`, use `--posterize-bits 4`, or lower `--fps` if Bluetooth transfer time is too high. Avoid reducing below `128x128` unless transfer time matters more than sharpness.

## Artifacts / tools

Captured/reconstructed artifacts:

- `captures/resend-btlogs/hci_snoop_2026_05_03_00_27_39.cfa`
- `captures/reconstructed/photo-transfer-reassembled.bin`
- `captures/reconstructed/photo-transfer.zst`
- `captures/reconstructed/photo-transfer-decompressed.bin`
- `captures/reconstructed/photo-transfer-preview.png`
- `captures/reconstructed/protocol-notes.md`

Scripts:

- `tools/parse_divoom_spp.py`
  - Parses tshark-exported SPP payloads.
  - Reassembles photo payload.
  - Strips per-frame checksums correctly.
  - Decompresses Zstd.
- `tools/send_divoom_image.py`
  - Converts an image or video/GIF-like frame sequence to Divoom payload/packet files.
  - Uses zstd `window_log=17` by default to match Android GIF sends.
  - Its pyserial send path is not preferred.
- `tools/DivoomRFCOMMSend.swift`
  - Direct IOBluetooth RFCOMM sender.
- `tools/divoom-rfcomm-send`
  - Compiled Swift sender binary.
- `tools/divoom-menubar`
  - macOS menu-bar controller for daemon lifecycle and image sending.

Working direct send example:

```bash
.venv/bin/python tools/send_divoom_image.py fixer.png --dry-run
blueutil --disconnect B1:21:81:B1:F0:84 || true
tools/divoom-rfcomm-send B1:21:81:B1:F0:84 1 captures/mac-send/fixer-packets-lenpref.bin 0.012
```

Known-good result:

- `fixer.png` was converted and sent successfully from macOS.
- Device returned final ACK:

```hex
01 09 00 04 bd 55 13 01 05 00 38 01 02
```

## Next improvement: daemon

Goal: avoid disconnect/reconnect noise for every image.

Implemented tools:

- `tools/DivoomDaemon.swift`
- `tools/divoom-daemon`
- `tools/divoom_send.py`
  - Preferred CLI for image/GIF/video sends through the daemon.
  - Supports MP4/video tuning: `--start`, `--duration`, `--fps`, `--speed`, `--max-frames`, `--size`, `--brightness`, `--contrast`, `--saturation`, `--posterize-bits`, `--sharpen`, `--zstd-window-log`.

Daemon behavior:

- Build a small daemon that opens direct RFCOMM channel `1` once.
- Keep the channel alive.
- Listen on localhost TCP `127.0.0.1:40583`.
- Accept JSON jobs containing a length-prefixed packet file path.
- For each job:
  - convert image
  - build packets
  - send start packet
  - wait for request if available
  - send chunks
  - wait for final ACK
- This should avoid repeated Bluetooth audio reconnect sounds.

Current usage:

```bash
# One-time start. If this fails with ret=0x-1ffffd44, disconnect the audio
# profile once, then start the daemon again.
blueutil --disconnect B1:21:81:B1:F0:84 || true
tools/divoom-daemon B1:21:81:B1:F0:84 1 40583
```

In another shell:

```bash
.venv/bin/python tools/divoom_send.py fixer.png
```

Dry-run through daemon, parsing the packet file but not sending to device:

```bash
.venv/bin/python tools/divoom_send.py fixer.png --daemon-dry-run
```

Build packet files only:

```bash
.venv/bin/python tools/divoom_send.py fixer.png --build-only
```

Validated smoke test:

```text
daemon: {"ok": true, "packets": 177, "message": "dry run", "bytes": 47384}
```

Expected successful real-send daemon response:

```json
{"ok":true,"message":"sent","packets":177,"bytes":47384,"sawRequest":true,"sawAck":true}
```

Important operational note:

- The daemon may need a one-time audio-profile disconnect before it can open RFCOMM channel `1`.
- Once the daemon holds the RFCOMM channel open, subsequent image sends should not require repeated disconnect/reconnect.
- In testing, daemon jobs sometimes reported `sent but final ACK not observed` while the device still updated correctly. Treat this as a daemon callback/ACK-observation issue, not necessarily a send failure.

## Menu-bar controller

Packaged app build:

```bash
tools/build-divoom-app.sh
```

This creates:

```text
build/Divoom MiniToo.app
```

Install/copy like a normal macOS app:

```bash
cp -R "build/Divoom MiniToo.app" /Applications/
open "/Applications/Divoom MiniToo.app"
```

Packaged app behavior:

- Runs as a menu-bar app (`LSUIElement`, no Dock icon).
- On launch/open, it automatically disconnects the Divoom macOS audio profile once, waits briefly, then starts the Swift RFCOMM daemon.
- The daemon binary is bundled inside the app at `Contents/Resources/tools/divoom-daemon` and keeps RFCOMM channel `1` open.
- Logs and generated send artifacts go to `~/Library/Application Support/DivoomMiniToo/` so the app can be copied to `/Applications` without writing into its bundle.
- `blueutil` is still required for audio disconnect/reconnect convenience actions (`brew install blueutil`).
- Image/GIF/video sending from the app shells out to the bundled Python venv when packaged.

Raw binary build/run from repo:

```bash
swiftc tools/DivoomMenuBar.swift -framework AppKit -o tools/divoom-menubar
```

Run from the repo root:

```bash
tools/divoom-menubar
```

Menu-bar title:

- `◇ Divoom` = daemon stopped
- `◆ Divoom` = daemon running

Menu actions:

- `Open Control Center…`
  - Opens a separate SwiftUI window (`tools/DivoomControlCenter.swift`)
    with a persistent device-controls bar pinned at the top (screen
    on/off toggle, brightness slider, and — once enabled in
    Preferences — a battery icon/percentage), and below it a home grid
    of function icons matching the real Divoom app's own navigation (tap
    an icon, drill into its controls, "Functions" back button to
    return), rather than a tab bar. Screens:
    - **Send Media** — choose a PNG/JPEG/GIF/video, builds and shows a
      preview (via `divoom_send.py --build-only`) before committing to the
      multi-second chunked upload, then "Send to Device". A "Full Screen
      (160×128)" checkbox switches from the default square `128x128`
      center-crop to the panel's full rectangular resolution (see "Full
      panel resolution" above) — toggling it rebuilds the preview.
    - **White Noise** — the 8 per-channel volume sliders plus a real on/off
      `Toggle` (replacing the old menu-only "off" item). Queries the
      device's actual current state (`WhiteNoise/Get`) on open, via a
      manual "Check Current State" button, and via a 3s auto-refresh timer
      that only runs while this screen is visible. Any toggle/slider edit
      re-fetches real device state first and applies the one change on top
      of it, so it can't clobber other channels back to stale local values.
    - **Custom Faces** — buttons to activate custom face 1/2/3.
  - Each screen resizes the window to its own actual measured content size
    (a `GeometryReader`-based mechanism, not hand-picked constants).
- Brightness slider
  - Shows both in the menu bar itself and in Control Center's
    device-controls bar — dragging either updates the same underlying
    state.
  - Native fast-path: builds `SPP_SET_SYSTEM_BRIGHT` (`0x74`) directly and
    talks to the daemon's TCP job socket, skipping Python/venv spin-up so
    dragging feels responsive.
- `Screen On` / `Screen Off` (Control Center device-controls bar only)
  - JSON `Channel/OnOffScreen`, native fast-path like brightness.
  - Dragging brightness to 0 turns the screen off automatically; raising
    it back up turns it back on.
- `Preferences…` (Cmd+,)
  - Opens a small SwiftUI window (`tools/DivoomPreferences.swift`) with:
    - **Show Dock Icon** — toggles `NSApp.setActivationPolicy` live
      between `.accessory`/`.regular`; clicking the Dock icon with no
      window open reopens Control Center.
    - **Show Battery Status** (off by default) — this device has no
      official battery command. When enabled, reads it one of two ways
      (both explicitly labeled as unsupported/private, either could break
      on a future macOS update):
      - *Log parsing* (default once enabled) — parses `bluetoothd`'s own
        diagnostic output (`log stream`) for its periodic `CBPowerSource`
        line. `CBPowerSource` is a real class inside the public
        `CoreBluetooth.framework` binary, but is completely undocumented
        (absent from every CoreBluetooth header) and populated internally
        by `bluetoothd` over a private XPC channel with no public entry
        point — its log text is the only observable public artifact.
      - *Private CoreUtils API* (experimental opt-in) — `dlopen`s
        `CoreUtils.framework` directly and drives
        `CUPowerSourceMonitor`/`CUPowerSource` via the Objective-C runtime
        (no headers exist, so there's no real linkage). Live,
        event-driven, no subprocess.
      - Once enabled, shows as an icon (scaled through SF Symbols'
        battery tiers) + percentage in Control Center's device-controls
        bar, and as a greyed-out row in the status-bar menu under "Audio
        profile".
- `Start Daemon`
  - Starts `tools/divoom-daemon` without disconnecting audio first.
  - Disabled while daemon is already running.
- `Disconnect Audio + Start Daemon`
  - Runs `blueutil --disconnect B1:21:81:B1:F0:84`, then starts daemon.
  - Use this if normal start fails because macOS audio owns the RFCOMM channel.
  - Disabled while daemon is already running.
- `Stop Daemon`
  - Terminates running `tools/divoom-daemon` processes.
  - Disabled while daemon is stopped.
- `Restart Daemon`
  - Stops daemon, disconnects audio, then starts daemon.
- `Disconnect Divoom Audio`
  - Lets phone/app connect again or frees RFCOMM.
  - Disabled when audio profile is already disconnected.
- `Reconnect Divoom Audio`
  - Requests normal macOS Bluetooth reconnect.
  - Disabled when audio profile is already connected.
- `Debugging Tools` submenu — `Open Captures Folder`, `Open Protocol Notes`,
  `Open Menu Log`, `Open Daemon Log` (grouped here once the menu started
  accumulating flat "Open ..." items that aren't day-to-day controls).

Current UX notes:

- The menu refreshes when opened, so daemon/audio status should reflect current state.
- The app avoids modal success/error popups; status appears as the `Last:` line in the menu.
- The packaged `.app` can be copied into `/Applications`; opening it is enough to disconnect audio once and start the daemon.
- Signed with any available codesigning identity (not ad-hoc) so macOS
  Bluetooth permission persists across rebuilds instead of re-prompting
  every time — ad-hoc signing has no Team ID, so TCC keys the grant off the
  binary's hash, which changes on every recompile.

## Custom face selection

Captured Android actions:

```text
custom face 1 -> ClockId 984
custom face 2 -> ClockId 986
custom face 3 -> ClockId 988
```

Third face confirmed by independent community reverse-engineering
([bugzmanov/divoom-minitoo](https://github.com/bugzmanov/divoom-minitoo),
via an authenticated Divoom account probe of `Channel/MyClockGetList`) —
not yet re-validated against our own device/account. MiniToo has exactly
three user-visible custom clock/face pages (`ClockType` 3/4/5 respectively);
that's a hardware/firmware limit, not an app UI limit.

The app sends JSON command `Channel/SetClockSelectId` as generic command `0x01`.

Captured body for custom face 1:

```json
{"ClockId":984,"Command":"Channel/SetClockSelectId","DeviceId":600111083,"DevicePassword":1777733348,"Language":"en","LcdIndependence":0,"LcdIndex":0,"PageIndex":0,"ParentClockId":0,"ParentItemId":"","Token":1777741943,"UserId":404779143}
```

Captured body for custom face 2 is the same except `ClockId=986`.

CLI:

```bash
.venv/bin/python tools/divoom_clock.py custom1
.venv/bin/python tools/divoom_clock.py custom2
# or any explicit clock id:
.venv/bin/python tools/divoom_clock.py 984
```

## Display settings: brightness

Reverse-engineered from the official Divoom Android app's `CmdManager.x2(byte)`,
which calls `SppProc$CMD_TYPE.SPP_SET_SYSTEM_BRIGHT` (opcode `116` / `0x74`).

```text
cmd  = 0x74
body = <level_u8>   # 0-100
```

Validated on device: `level=10` visibly dims the screen, `level=100` returns
it to full brightness.

CLI:

```bash
.venv/bin/python tools/divoom_display.py brightness 100
```

## Explored, not applicable to MiniToo: "screen dir cfg" / rotation

`SppProc$EXT_CMD_TYPE.SPP_SECOND_SET_SCREEN_DIR_CFG` (`35`, sent via the
extended-command wrapper `SPP_DIVOOM_EXTERN_CMD` / `0xBD`) looked, from the
enum name alone, like a candidate for physically rotating the display 180°.

Tested on hardware with mode bytes `0, 1, 2, 3`: no visible effect.

Tracing the Android app's actual UI consumer (`LightSettingsFragment.java`,
under "More > Light Settings") shows this control is a `RadioGroup` bound to
values `30/60/180/360/720/0` next to a mirror toggle, intensity seek bar, and
shake/auto-connect switches — an ambient RGB light auto-cycle timer for a
*different* Divoom product line (e.g. a light cube/panel), not the MiniToo
pixel screen. Divoom's `SppProc$CMD_TYPE`/`EXT_CMD_TYPE` opcode space is
shared across their whole catalog, so this opcode number is simply reused
for an unrelated feature on other hardware; MiniToo's firmware appears to
silently ignore it.

No genuine screen-orientation/flip command was found elsewhere in the
decompiled app for this device. Given MiniToo's fixed desk-facing form
factor (unlike e.g. Tivoo's swiveling stand), it likely doesn't have a
rotation feature at all. Not implemented in the Mac tooling.

## Community cross-reference

Independent prior work was reviewed and cross-checked against our own
decompile-derived findings (2026-07-05). Sources:

- [bugzmanov/divoom-minitoo](https://github.com/bugzmanov/divoom-minitoo) —
  extensive empirical hardware probing against a MiniToo, same firmware
  2.4.0. By far the richest source; see its `FINDINGS.md`.
- [ztomer/divoom_lib](https://github.com/ztomer/divoom_lib) — includes a
  scrape of Divoom's *official* developer docs
  (`docs/divoom_docs/`, from `docin.divoom-gz.com`), the canonical
  reference for opcode byte layouts across Divoom's whole product line.
- [d03n3rfr1tz3/hass-divoom](https://github.com/d03n3rfr1tz3/hass-divoom) —
  Home Assistant integration with a generic Divoom opcode map (not
  MiniToo-specific, but useful cross-confirmation).
- [estlin/divoom-stats](https://github.com/estlin/divoom-stats) — a Swift
  macOS project that already consumes *our own* `PROTOCOL.md` for the
  0x8b image path; no new findings, but confirms our envelope/checksum
  understanding is being relied on elsewhere.

### Confirmed matches (independent confirmation of what we already had)

- Frame envelope (`01 len cmd body checksum 02`), checksum algorithm.
- `0x74` = Set brightness, single byte 0-100 — matches the *official*
  Divoom docs verbatim. This directly resolves a conflict where
  bugzmanov's notes claimed `0x74` "not visible on MiniToo, `0x32` is the
  one" — our own hardware test (dimmed at 10, full at 100) combined with
  the official doc confirmation outweighs that untested claim. No action
  needed; keep using `0x74`.
- `0x43`/`0x42` = Set/Get alarm time, byte layout (`alarm_index, on_off,
  hour, minute, week_bitmask, mode, trigger_mode, fm[2], volume`) —
  matches the *official* Divoom docs (`alarm_memorial.md`) field-for-field
  with what we independently derived from decompiling `CmdManager.x0()`.
  This substantially raises confidence for the alarm feature: bugzmanov's
  probe logged `0x42` as "silent" on their unit, but a passive GET probe
  going unanswered doesn't necessarily mean `0x43` SET has no effect —
  worth a direct, deliberate hardware test (set a near-future alarm, listen
  for it to fire) rather than treating it as settled either way.
- `0xa0` = Set game, `0x72` = Set tool view — matches our own findings.

### New capabilities found

- **Screen on/off** — JSON `{"Command":"Channel/OnOffScreen","OnOff":0|1}`,
  or raw `SPP_DIVOOM_EXTERN_CMD` (`0xBD`) + ext `SPP_SECOND_OPEN_SCREEN_CTRL`
  (`0x2F`) with arg `0`=off, `1`=on/restore, `2`=no-op, `3`=off. Confirmed
  working on real MiniToo hardware by bugzmanov, and independently
  hardware-tested here. **Implemented** — `tools/divoom_display.py screen
  on|off` plus a `Screen On`/`Screen Off` menu-bar item (native fast-path).
- **Third custom face** — see "Custom face selection" above. **Implemented**
  — `ClockId 988` wired into `tools/divoom_clock.py`'s shortcut dict and
  Control Center's "Custom Faces" screen.

### Not yet implemented here

- **ANCS-style text notification** — opcode `0x50`
  (`SPP_SET_ANDROID_ANCS`), body = `[icon_slot_u8, text_len_u8,
  utf8_text...]`. Flashes an icon (24 preset app icons: Instagram,
  WhatsApp, Discord, Telegram, etc.) + up to 128 bytes of text for ~1-3s,
  then reverts to the previous view. No pixel upload needed. Confirmed
  reliable on hardware. Good candidate for a quick "flash a status
  message" feature — a natural fit as a composer screen in Control Center.
- **Tool views** (opcode `0x72`) — stopwatch, scoreboard, noise meter,
  countdown. Scoreboard and noise meter are silent/safe; **stopwatch and
  countdown trigger an audible alarm** when they cross a boundary/hit
  zero — avoid at night. There is no software "return to clock face"
  command for any tool view; only the physical button exits it.

### Not incorporated

The rest of bugzmanov's `FINDINGS.md` (photo/gallery upload, `0x8B` live
animation variants, custom-face server-file emulation via fake `FileId`,
eZip native-library bridging) covers ground our existing `0x8b` GIF path
and `Channel/SetClockSelectId` custom-face switching already handle for
our use case, or requires a Divoom cloud account (out of scope, same as
the community-sync findings above). Not re-implemented here to avoid
scope creep; revisit if a specific need comes up.

## White noise

**Confirmed Bluetooth-reachable and working**, correcting an earlier
conclusion in this document. The command-routing classification in the
decompiled APK (`HttpCommand.java`'s static arrays) suggested `WhiteNoise/*`
was HTTP-only, but the actual runtime call in
`com/divoom/Divoom/view/fragment/whiteNoise/model/WhiteNoiseModel.java`
branches on device architecture:

```java
if (DeviceFunction.WifiBlueArchEnum.getMode() == DeviceFunction.WifiBlueArchEnum.BlueArchMode) {
    q.s().B(whiteNoiseSetRequest);   // direct Bluetooth SPP_JSON send
} else {
    // HTTP path, WiFi-arch devices only
}
```

MiniToo is `BlueArchMode`, so both `WhiteNoise/Get` and `WhiteNoise/Set` go
straight over Bluetooth SPP_JSON (cmd `0x01`), the same path as the
already-working `Channel/SetClockSelectId`.

### JSON structure

```json
{"Command":"WhiteNoise/Set","OnOff":0|1,"Time":<minutes,0=permanent>,"EndStatus":0|1,"Volume":[v0,v1,...,v7]}
```

- `Volume` is an 8-element array, one entry per ambient sound, range 0-100.
  Multiple channels can be non-zero simultaneously — the device **mixes**
  them (confirmed on hardware: rain + fire play together).
- `OnOff` is a master switch; `Time` is an optional sleep-timer duration in
  minutes (`0` = no timer); `EndStatus` meaning not fully mapped (tied to
  two UI radio buttons, `rb_shutdown`/`rb_standby`, in
  `WhiteNoiseMainFragment.java` — left at `0` in our tooling).
- Setting any channel to a non-zero volume while `OnOff:1` is enough to
  make that sound play; `OnOff:1` with an all-zero `Volume` array is
  silent (master on, everything muted) — this is almost certainly why an
  earlier community probe (bugzmanov, naive `WhiteNoise/Set` test) saw "no
  visible effect": their own `WhiteNoise/Get` snapshot showed an all-zero
  `Volume` array.

### Channel mapping

Confirmed by ear against real hardware, 2026-07-05:

| Index | Sound |
| --- | --- |
| 0 | Fan |
| 1 | Frogs |
| 2 | Fire |
| 3 | Waves |
| 4 | Rain |
| 5 | River |
| 6 | Birdsong |
| 7 | Singing bowls |

CLI:

```bash
.venv/bin/python tools/divoom_whitenoise.py get
.venv/bin/python tools/divoom_whitenoise.py set rain 40
.venv/bin/python tools/divoom_whitenoise.py off
```

The menu bar app exposes all 8 channels as independent sliders (mixable),
plus an "Off (all channels)" reset, under White Noise.
