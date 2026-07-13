# Divoom MiniToo Bluetooth Photo Protocol

Notes from reversing the Divoom Android app + Android Bluetooth snoop captures, then validating sends from macOS.

## ⚠️ Safety: sleep-control opcodes reported to require a power-cycle

Independent community reverse-engineering
([bugzmanov/divoom-minitoo](https://github.com/bugzmanov/divoom-minitoo))
and a generic Divoom device map
([d03n3rfr1tz3/hass-divoom](https://github.com/d03n3rfr1tz3/hass-divoom))
report that these opcodes can put a MiniToo into a black-screen "sleep
monitoring" state that does **not** respond to recovery commands
(`Channel/OnOffScreen`, `Lyric/Enter`, `Photo/Enter`, `Channel/SetBrightness`,
game-exit, screen-ctrl) — only a **hardware power-cycle** recovers it.

This specific failure has **not** been observed firsthand in this project;
the claim remains externally sourced. Treat it as a safety interlock, not a
hardware-verified result, until a deliberately planned capture-first test is
authorized and physically observed.

**Never send:** `0x40` (set sleep auto off), `0xa3` (set sleep scene listen),
`0xa4` (set scene vol), `0xad` (set sleep color), `0xae` (set sleep light).

Do not probe this family further without a hardware power button within reach.

## Device / transport

- Device: `Divoom MiniToo-Audio`
- Bluetooth address: no longer hardcoded — discovered via an in-app scan and cached (see README's "First-time setup"); `B1:21:81:B1:F0:84` below is just an example value for illustrative commands.
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
01 08 00 8b 00 a1 2e 00 00 62 01 02
```

(Checksum bytes corrected 2026-07-11: the transcribed example previously
showed `ae 01` here, which doesn't match the `frame()` algorithm directly
above when run against this same cmd/body -- recomputed independently
against that reference algorithm during unit-test work, see
`Tests/DivoomMiniTooTests/DivoomRawFrameTests.swift`. Not a sign of a code
bug: `DivoomRawFrame.build`/`DivoomChunkedUpload` implement this exact
algorithm and are hardware-confirmed working, so this was a doc
transcription slip, not evidence the device expects a different checksum.)

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
- **Resolved (2026-07-10):** a 160x128 still-image send previously produced
  no final ACK and crashed the MiniToo; the menu UI disabled full-screen
  sends pending a regression diff. Root cause: the app-side preview-build
  packet file was named from the media filename alone with no per-build
  uniqueness, so a concurrent rebuild (e.g. toggling Full Screen shortly
  after picking a file) could race on that path and leave a later send
  pointed at a torn/mismatched packet file. Fixed in
  `tools/DivoomControlCenter.swift` (per-build output directories, stale
  completions ignored); full-screen sends are re-enabled and
  hardware-confirmed working for both still image and MP4/video. Full
  root-cause writeup in `docs/local/dev-notes.md`.

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
- `IOBluetoothRFCOMMChannel` writes must happen on the same thread that opened the channel — a background-thread `writeSync` call reports success while sending nothing on the wire. This is what the daemon's write-timeout handling guards against.

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
      device's actual current state (`WhiteNoise/Get`) on open and via a 3s
      auto-refresh timer that only runs while this screen is visible. Any
      toggle/slider edit re-fetches real device state first and applies the
      one change on top of it, so it can't clobber other channels back to
      stale local values. **Auto-refresh is quiet by default** (see
      `AutoRefreshToggle` below) — a routine poll that finds nothing changed
      doesn't touch the status line or show a busy spinner; only a real
      problem (unreadable reply) surfaces there. The old manual "Check
      Current State" button was removed since auto-refresh runs by default;
      a small `AutoRefreshToggle` control (switch + "Auto-refresh (3s)"
      label, bottom-right of the status line) lets the user turn the
      periodic polling off entirely instead.
    - **Custom Faces** — buttons to activate custom face 1/2/3.
    - **Photo Album** — choose a photo, preview, "Add to Album" — uploads
      into the device's *persistent* on-device photo gallery (see "Photo
      Album" section below), distinct from Send Media's live/ephemeral
      push. No album/ID selection needed; the device has one flat gallery.
    - **Atmosphere** — a grid of 21 numbered background buttons plus 6
      text-effect buttons (see "Atmosphere" section below); selecting either
      sends `Lyric/Enter` + `Lyric/SetConfig` natively (no Python
      subprocess), same fast-path pattern as brightness/white noise.
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

### Populating the empty custom-face slots: known dead ends

All 3 custom-face slots (`ClockId` 984/986/988) are currently empty on this
device — selection works, but how the official app actually populates a
slot with a custom animation/image is still unknown. From bugzmanov's
`FINDINGS.md` cross-reference, these paths have already been tried and
confirmed **not** to be it, to save re-treading them in a future capture
session:

- **`0xBE`, fake-`FileId` custom-face emulation** — re-uploads the payload
  on every single face switch instead of a real one-time persistent write;
  not actually the "instant" on-device slot it should be.
- **`0x8C`, stored-animation slots** — never produced any device response
  at all.
- **General photo/gallery upload** (the `0x8F` path documented under
  "Photo Album" below) — writes into the device's single shared gallery,
  with no way to pin one image to a specific custom-face slot.

Most likely path forward: a real Bluetooth HCI-snoop capture of the
official app populating a slot, same method used to resolve Photo Album
below.

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
- **Tool views** — Android HCI captures establish `0x71 [tool]` as a tool
  read and `0x72` as the tool action command. Two tools are now implemented
  and directly hardware-tested through the native Control Center:
  - Stopwatch (tool `0`): `[0,1]` Start, `[0,0]` Pause, `[0,2]` Reset.
  - Noise Meter (tool `2`): `[2,1]` Start, `[2,2]` Stop. It uses the
    MiniToo's onboard microphone; no numeric level readback has been
    established, so the app does not invent one.
  There is no software "return to clock face" command for either tool;
  the physical button exits it.

### Not yet implemented here

- **ANCS-style text notification** — opcode `0x50`
  (`SPP_SET_ANDROID_ANCS`), body = `[icon_slot_u8, text_len_u8,
  utf8_text...]`. Flashes an icon (24 preset app icons: Instagram,
  WhatsApp, Discord, Telegram, etc.) + up to 128 bytes of text for ~1-3s,
  then reverts to the previous view. No pixel upload needed. Confirmed
  reliable on hardware. Good candidate for a quick "flash a status
  message" feature — a natural fit as a composer screen in Control Center.
- **Remaining tool views** (opcode `0x72`) — Scoreboard and Countdown are
  capture-derived but not yet implemented. Scoreboard is silent/safe;
  Countdown can trigger an audible alarm at zero — avoid late-night testing.

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

## Photo Album (persistent on-device photo storage)

Architecturally distinct from the "Photo / animation command" section
above (`0x8b`, `SPP_APP_NEW_GIF_CMD2020`): that path is a live, ephemeral
pixel push (nothing survives reboot/disconnect, requires the daemon
running every time). This section is the official app's actual **persistent**
photo storage — upload once, it stays on the device across reboots,
displayed in a single flat gallery (no albums/IDs — the device really only
has one gallery, confirmed both by direct observation and by the capture
below finding no album-selection step of any kind).

**Provenance:** this protocol was decoded from a real Bluetooth HCI snoop
capture of the official Divoom Android app performing this exact action
against a real MiniToo — not from decompiled APK source, which traced a
different, apparently-unused code path (`BluePhotoModel`'s JSON
album-management + a 12-byte photo header + eZip encoding) that produced
three wrong theories in a row and two real device crashes before the real
capture resolved it in one shot. See `tools/divoom_album.py`'s module
docstring and this repo's development history for the full story if it
matters later.

### Protocol

1. `{"Command":"Photo/Enter","DeviceId":<id>,"Token":<token>,"UserId":<id>}`
   — plain JSON over `SPP_JSON` (`0x01`). This is the **only** JSON command
   involved — no `Photo/NewAlbum`, `Photo/LocalAddToAlbum`, or
   `Photo/PlayAlbum`, and no `ClockId`/album addressing at all.
2. `SPP_LOCAL_PICTURE` (`0x8F`) binary transfer of a small custom "blob":
   - **Announce**: a 5-byte body, `[0x00][blob_size_u32_LE]`. Notably
     *not* the more complex 12-byte header (marker + size + photoFlag +
     fileType + totalCount + fileIndex) that a decompiled-code trace of
     `BluePhotoModel.n()` suggested — sending that longer header format
     crashed the device.
   - **Chunks**: `[0x01][blob_size_u32_LE][chunk_index_u16_LE][<=256B payload]`
     — same shape as the `0x8b` chunk format elsewhere in this doc.
3. **The blob itself** (what gets chunked) has its own small header,
   distinct from the `0x25`-marker header used by the `0x8b` live-draw
   path:

   ```text
   1f                  marker (unique to this feature; 0x25 is the 0x8b one)
   01                  frame count (always 1 in the capture; multi-frame untested)
   <speed_be16>        milliseconds, big-endian (2000 in the capture)
   <row_blocks_u8>     16px blocks; 8 = 128px
   <col_blocks_u8>     16px blocks; 10 = 160px (full panel width)
   <jpeg_len_be32>      big-endian length of the JPEG that follows
   <jpeg_bytes>        a plain, standard JPEG -- NOT WebP, NOT eZip
   ```

   The JPEG is a real JFIF file with an embedded ICC color profile, exactly
   what Android's own `Bitmap.compress(JPEG, ...)` produces — nothing
   Divoom-specific about the image encoding itself, only the small
   `0x1f`-marker wrapper header around it.

### Implementation

`tools/divoom_album.py add-photo <image>` — cover-crops/resizes to the full
160x128 panel, JPEG-encodes (quality 90 default), wraps in the blob header,
and uploads. Exposed in the menu-bar app's Control Center as a "Photo
Album" screen (choose a photo, preview, "Add to Album") — hardware-tested
end-to-end: an uploaded test image appeared correctly and persistently in
the gallery alongside a real photo added moments earlier via the official
Android app in the same session.

**Stills only — not a gap in this implementation.** The blob header has a
`frame_count` field, suggesting multi-frame (GIF/video) content is part of
the same protocol family, but the *official Divoom app itself* fails to
add a video/GIF to this specific feature on the current app version
(picker shows a black/generic preview, "Send" does nothing — confirmed
directly on the same Android setup used for the capture above). A
same-session hardware test here of the natural extension (concatenate
self-delimiting JPEGs after one combined length field, `frame_count>1` —
the same structural pattern the sibling `0x8b` protocol already uses for
its own multi-frame payload) uploaded without crashing but displayed only
as a static first frame — consistent with the real app not actually
supporting this either right now, not with our own encoding being wrong.
Not pursued further; revisit only if a future app version is confirmed to
support it, ideally re-verified with a fresh capture rather than more
guessing.

### How the capture was obtained

Useful to remember if a similar investigation is needed again — see also
the standing project preference for this technique over APK tracing.

1. Android tablet, official Divoom app, paired with the MiniToo through the
   app's own in-app "add device" flow (system-level Bluetooth pairing alone
   only connects the generic audio profile — volume works, JSON commands
   don't, mirroring this project's own daemon needing to disconnect audio
   before opening the RFCOMM control channel).
2. Developer Options → "Enable Bluetooth HCI snoop log".
3. Perform the real action once in the official app.
4. `adb bugreport out.zip` — on modern Android the raw log isn't directly
   readable from `/sdcard`; it's bundled inside the bug report zip at
   `FS/data/misc/bluetooth/logs/*.cfa.curf`. Despite the unusual extension,
   it's the standard `btsnoop` file format (confirmed via its `btsnoop\0`
   magic header) and parses directly.
5. Parse: HCI ACL header (`<HH` handle+flags, `<HH` L2CAP length+CID) →
   L2CAP payload → RFCOMM header (address byte's DLCI, control byte, 1-or-2
   byte length depending on the length byte's EA bit — **watch for an
   extra credit byte** inserted right after the length field whenever the
   control byte's P/F bit is set, i.e. `control & 0x10`, from RFCOMM's
   credit-based flow control extension) → the actual SPP payload, which
   uses this project's already-documented `01 <len_le16> <cmd> <body>
   <checksum_le16> 02` framing.
6. The MiniToo's Bluetooth link is fragile to multiple nearby devices
   competing for it — keep every other device's Bluetooth off during the
   capture session.

## Atmosphere (animated background selector)

The app's "Atmosphere" screen: a grid of ~21 selectable animated/static
backgrounds (VU meters, waveforms, spectrum circles, starfields, cityscapes,
etc.), plus a separate row of "Text effects" (Mix/Dissolve/Push Up/Push
Left/Rotate/None in the app's UI).
Decoded from a real BT HCI snoop capture (same methodology as Photo Album
above) of the official app selecting a spread of backgrounds and all 6
text-effect options.

**Naming hint, worth taking seriously:** the wire commands are
`Lyric/Enter`/`Lyric/GetConfig`/`Lyric/SetConfig`, not anything
"Atmosphere"-named — despite the screen being labeled "Atmosphere" in the
app's UI. Combined with the background choices all being audio-reactive
visualizations (VU meters, spectrum circles, waveforms) and the separate
"Text effects" row, this is most plausibly Divoom's music-synced **lyrics
display** mode: `Background` picks the visual backdrop, and `TextEffect` is
likely a lyric-text animation style (scroll/fade/karaoke-highlight/etc.)
that only actually renders something while a song with lyrics is playing
and being fed to the device. This would explain the hardware test result
below — treat this as the working theory, not confirmed, until tested with
real music playing.

### Protocol

Three JSON commands, all opcode `0x01`, no binary transfer involved at all
— much simpler than Photo Album:

- `{"Command":"Lyric/Enter","DeviceId":...,"Token":...,"UserId":...}` —
  switches the device into the Atmosphere view.
- `{"Command":"Lyric/GetConfig","DeviceId":...,"Token":...,"UserId":...}` —
  queries current config. **Does get a real reply**, confirmed via a fresh
  BT capture read: `{"Command":"Lyric/GetConfig","Background":N,
  "TextEffect":N}` (pretty-printed with `\n`/`\t` on the wire). An earlier
  pass wrongly concluded there was no reply — that was a parser bug, not a
  device limitation: the reply arrived on a *different* L2CAP CID than the
  one the outgoing command used (each direction of a bidirectional L2CAP
  channel gets numbered independently by each endpoint), and the initial
  investigation only checked the CID the command itself was sent on. Also
  hit a second, related parser bug while re-checking this: the reply is
  long enough (pretty-printed JSON) to span more than one HCI ACL fragment,
  which `parse_btsnoop_rfcomm.py`'s original naive per-ACL-packet parsing
  silently mis-decoded as a bogus extra "CID". Both fixed in that script
  (see its module docstring) — it now does real ACL reassembly using the
  PB (packet boundary) flag bits before parsing L2CAP/RFCOMM.
- `{"Background":<int>,"Command":"Lyric/SetConfig","DeviceId":...,
  "TextEffect":<int>,"Token":...,"UserId":...}` — selects a background and a
  text effect. `Background` is 0-indexed into the grid (0-20 observed across
  15 captured selections spanning that full range, confirming ~21 total
  entries). `TextEffect` is 0-5; per the user reading the on-device labels
  directly, the 6 named options in order are: **Mix, Dissolve, Push Up,
  Push Left, Rotate, None** — note index 0 is "Mix", not "off"; the actual
  off state is index 5 ("None"). Both fields vary independently and take
  effect immediately with no other fields required.

**`Background`'s 21 names are also known now**, per the user reading them
directly off the device (not from a fresh capture — see `Background`
index caveat below): **Pulsation, Vitality, Sound Wave Ring, Rhythm,
Melody, The Album, Pink Space, Bubbles, Blue Sky, Vinyl, Starlight, Night
View, Sunset, Quicksand, Gradient, Geometry, Black Hole, Imagination,
Vaporware, Sunrise, Photo Album** (indices 0-20 in that order). Index 20
("Photo Album") confirms the earlier guess that this slot is a "use your
own photo" tile, not a generated visual. These names corroborate (without
independently BT-proving) the row-major index<->grid-position assumption
used when building the icon set below — several line up thematically well
(2 "Sound Wave Ring", 7 "Bubbles", 9 "Vinyl", 16 "Black Hole", 18
"Vaporware", 20 "Photo Album").

### Implementation

`tools/divoom_atmosphere.py` — CLI with `enter`, `get`, and
`set --background N [--text-effect N]` subcommands, same
build/write-packets/submit pattern as the other `tools/divoom_*.py` scripts;
`BACKGROUND_NAMES`/`TEXT_EFFECT_NAMES` used for CLI help text and for
printing a friendly `set:`/`device state (named):` line alongside the raw
indices. Also wired natively into Control Center as an "Atmosphere" screen
(`AtmosphereModel`/`AtmosphereView` in `DivoomControlCenter.swift`): a
7x3 grid of small icon buttons for `Background` (original vector
reinterpretations of each background's general look — see
`tools/DivoomAtmosphereIcons.swift` — since Divoom's actual artwork is
their IP and isn't reproduced here; each button's tooltip shows the real
name) plus a dropdown `Picker` for `TextEffect` showing the 6 real names
above. Status text after any send/refresh shows the real background/effect
names, not raw indices. Each selection sends
`Lyric/Enter` then `Lyric/SetConfig` as two separate native `DivoomRawFrame`
jobs (no Python subprocess) for a snappy feel, mirroring the white-noise
screen's fast-path pattern. An automatic refresh on opening the screen and
a 3s auto-refresh timer while the screen stays open (skipped while busy,
toggleable via the same `AutoRefreshToggle` control White Noise uses) send
`Lyric/Enter` + `Lyric/GetConfig` with `waitForReply`, parse the real
device reply, and update the highlighted background icon / dropdown
selection to match — same pattern as `WhiteNoise/Get`'s refresh in the
White Noise screen, including the quiet-unless-there's-a-problem behavior
(no status-text/busy flicker on a routine poll that finds nothing
changed). Hardware-confirmed working, including picking up an externally
-made change (set via the CLI while the screen was open, moved to the
right icon on the next poll tick with no flicker) and stopping the polling
promptly when the window closes.

**Icon quality is a known, deliberately deferred to-do (2026-07-06):** the
21 background icons are original hand-drawn SwiftUI vector shapes, good
enough to be recognizable but not visually polished — the user plans to
run them through some kind of AI image-unification pass later to make them
look consistent/nicer, which isn't something achievable here without an
image-generation tool. Don't spend further effort polishing individual
icon shapes unless asked; this is parked, not forgotten.

**Real bug found and fixed during hardware testing**: both `divoom_atmosphere.py`
and `AtmosphereModel` originally bundled `Lyric/Enter` + `Lyric/SetConfig`
into one two-packet daemon job (matching how Photo Album bundles its
multi-packet upload). That was wrong for this feature — the daemon's
multi-packet code path in `sendJob` waits for the chunked image/photo-transfer
request/ACK handshake, which plain independent JSON commands never trigger,
so it falsely reported `ok:false`/"final ACK not observed" even though every
packet was actually sent over the wire correctly. Fixed by sending `Enter`
and `SetConfig` as two separate single-packet jobs instead (each of which
takes the daemon's fire-and-forget `ok:true` fast path), in both the Python
CLI and the Swift model.

**Hardware-tested (2026-07-06), both via CLI and the real Control Center
UI** (clicked through the actual app using System Events + cliclick, not
just called the daemon directly): selecting `Background` 0, 3, and 5 each
visibly changed the device's screen to a different animated visual,
confirmed directly by the user each time. Selecting a `TextEffect` (tested
value 2) produced no visible change with no music playing, consistent with
the "Lyric" naming theory above. Treat `Background` switching as solid.

### `TextEffect`/lyric text — confirmed mechanism is AVRCP, not SPP_JSON (2026-07-07)

**Confirmed via a real BT HCI snoop capture** (Android tablet, a
third-party "Bluetooth car lyrics" title-swapping app playing a local
track, no official Divoom app involved in this specific test) that lyric
*text* can ride the **standard AVRCP profile** without ever touching
`Lyric/SetConfig`. This is confirmed as *a* working path, not proven to be
the *only* one — no genuine music-lyrics-sync app was tested (only a
title-swap workaround), and a second, decompile-only candidate exists (see
"Music Name display style" below) that hasn't been ruled in or out. It
rides the
(Company ID `0x001958` — the Bluetooth SIG's own vendor ID, not Divoom's)
that's already active on any Bluetooth-audio-connected phone, entirely
independent of the `0x01 SPP_JSON` channel this project has been
capturing everywhere else.

Confirmed trigger chain, from `captures/lyrics-avrcp-test.cfa.curf`
(L2CAP CID 130 carried every hit; parsed with
`parse_btsnoop_rfcomm.py`'s `parse_l2cap_frames()`, since AVRCP uses AVCTP
framing, not RFCOMM, so the script's `--cid` RFCOMM decode path doesn't
apply here — text was located by grepping reassembled L2CAP payloads
directly):

1. Phone sends `RegisterNotification` response, `ctype=CHANGED`,
   `EventID=0x02` (`TRACK_CHANGED`) — the phone's media session considers
   the current track "new" (see below for why).
2. MiniToo immediately re-registers for the same event; phone acks
   `ctype=INTERIM`.
3. MiniToo issues `GetElementAttributes` (PDU `0x20`); phone responds
   `ctype=STABLE` with the attribute list — `AttributeID=1` (Title),
   `AttributeID=2` (ArtistName), etc., each as a UTF-8 string with a
   2-byte length prefix. Example decoded payload:
   `AttributeID=1, CharSet=UTF-8(0x006A), Len=13, Value="Lavender Haze"`
   followed by `AttributeID=2, Len=12, Value="Taylor Swift"`.

**So the MiniToo is the AVRCP *Controller* (it polls/reacts), and the
phone is the AVRCP *Target* (it answers)** — this is the same standard
"Now Playing" title-display mechanism any basic Bluetooth speaker/car
head unit implements, just repurposed by lyric-hack apps to shove lyric
lines into the Title field instead of a real song title.

**Why the observed titles alternated between `"Lavender Haze"` (13 bytes)
and `"Lavender Haze "` (14 bytes, trailing space)**: the MiniToo only
re-fetches metadata off a `TRACK_CHANGED` event, not on a timer/poll
loop. A lyrics app pushing successive lines needs each push to look like
a genuinely new track to the phone's own media-session/AVRCP stack, or
`TRACK_CHANGED` never fires and the display never updates — the trailing
-space toggle is a cheap way to force that, seen alternating across the
full capture every time the app pushed a new value.

**Implication for this project**: since this is standard AVRCP, not a
Divoom-specific command, there is nothing new to add to `CmdManager`/the
daemon's opcode set — no brick risk, no new opcode.

### macOS metadata routing: current evidence and limits

`MPNowPlayingInfoCenter` was physically negative in three tests
(2026-07-07): bare metadata, metadata with a real silent `AVAudioEngine`
route to MiniToo, and real Music.app playback routed to MiniToo all showed
no title on the device. These tests rule out the public now-playing API as a
working solution *in those configurations*.

An earlier interpretation of one `log stream` run as proof that macOS sends
Now Playing only to Apple accessories has been **withdrawn**. That run showed
only the paired AirPods in an Apple Smart Routing log path and did not prove
that this was the system AVRCP routing decision for every third-party device.
Do not repeat that claim.

A later controlled trace (`~/Desktop/minitoo-avrcp-track-change.log`,
2026-07-09) did prove that A2DP was active and the MiniToo's physical Next
Track command reached Music.app through `bluetoothd`. During the same run,
neither a MiniToo `GetCapabilities`, `RegisterNotification(TRACK_CHANGED)`,
nor `GetElementAttributes` request was observed. This is strong evidence that
the MiniToo did not start its metadata-polling sequence against this Mac; it
is not a packet-level proof that macOS would reject such a request.

The leading interoperability hypothesis is the SDP advertisement, not a
settled root cause. A Dell SDP browse found the Mac AVRCP Target advertises
profile `0x0106` and SupportedFeatures `0x0011`, while the Android tablet
that produced the working capture advertises `0x0105` and `0x00d1` (including
Browsing and Multiple Players bits). A conforming AVRCP Controller should
not need those additional bits for basic metadata, but MiniToo may gate its
polling incorrectly. Test that hypothesis before treating it as fact.

PacketLogger is currently not a usable way to settle this on the M3: the
current PacketLogger authenticated and reported live logging, yet emitted
zero HCI/ACL packets during real Bluetooth activity. The macOS Bluetooth
logging profile and unified logs can still help diagnose state, but they are
not a substitute for an over-air capture.

**But the MiniToo's own AVRCP client is directly reachable by bypassing
macOS's system handling entirely — confirmed working 2026-07-07.**
Using the same pattern the daemon already uses for RFCOMM
(`IOBluetoothDevice(addressString:).openRFCOMMChannelSync` — see
DivoomDaemon.swift), a minimal Swift probe called
`IOBluetoothDevice(addressString:).openL2CAPChannelSync(&ch, withPSM:
0x17, delegate:)` (PSM `0x17` = AVCTP):

- **While the Divoom audio profile is connected** (macOS's own
  Bluetooth Audio stack already owns the AVRCP L2CAP channel for that
  connection): fails immediately, `IOReturn 0xe00002bc` (`kIOReturnError`,
  IOKit's generic failure code — not a specific Bluetooth error).
- **With the Divoom audio profile disconnected first** (same
  precondition the daemon already requires for RFCOMM): **succeeds**,
  `ret=0x0`. And within milliseconds, before anything was sent to it,
  the MiniToo pushed a real unsolicited AVRCP request over the new
  channel:

  ```
  10 11 0e 01 48 00 00 19 58 10 00 00 01 03
  ```

  Decoded: `10` AVCTP header (command, single packet) · `11 0e` Profile
  ID `0x110E` (AVRCP) · `01` AV/C ctype `STATUS` · `48` subunit
  PANEL/0 · `00` opcode VENDOR-DEPENDENT · `00 19 58` Company ID
  `0x001958` (same Bluetooth SIG ID as the Android capture) · `10` PDU
  `GetCapabilities` · `00` single packet · `00 01` 1-byte parameter ·
  `03` CapabilityID `EVENTS_SUPPORTED`. That's the real opening
  handshake of an AVRCP session — same protocol as the Android capture,
  confirmed independently against the Mac.

  **Tradeoff**: this only works with the OS-managed audio profile
  disconnected, so no real Mac-sourced audio plays through the MiniToo
  while it's active — pushing custom text this way and playing real
  audio from the Mac at the same time are currently mutually exclusive.
  Fine for a "push arbitrary text to the screen" feature independent of
  real playback; not yet a solution for "show what Apple Music is
  actually playing" while that audio is audible.

  **Not yet built**: only `GetCapabilities` has been observed so far —
  answering it plus `RegisterNotification`/`GetElementAttributes`
  ourselves (to actually push custom title text) is real protocol
  implementation work, still to do. See `docs/local/dev-notes.md`'s
  macOS lyric-delivery section for the play-by-play and next steps.

**Existing-AVRCP-channel research (2026-07-09):** normal audio and MiniToo
controls would coexist cleanly if `bluetoothd`'s own AVRCP Target record
could be changed: it would still own AVCTP PSM `0x17`. That is not available
to a normal app. The daemon's private Classic XPC machinery can add/remove
client-owned SDP records, but no update/replace operation was found; a
conflicting PSM gets reassigned, so it cannot alter the system record.
Patching `bluetoothd` as it creates its record could make a valuable
one-variable experiment on a disposable macOS installation, but requires
weakening system protections and is not a shippable technique. See local
dev notes for the product decision. **Decision (2026-07-10):** shelve live
Mac-audio-plus-lyrics delivery. A Linux bridge/Android companion is outside
this project's accepted scope, and the remaining experiments could explain
the interop failure but cannot yield a supported, shippable macOS solution.
Revisit only if macOS gains a supported AVRCP metadata-target API or the
MiniToo/macOS behavior materially changes.

**Confirmed by direct user observation (2026-07-07)**: the MiniToo only
ever rendered the Title text on screen during this test — the Artist
attribute (`AttributeID=2`) is present in every captured response
alongside the title but was never visible on the device. So the on-device
renderer for this feature is title-only.

**Delay — only partially measurable from this capture**: wire time from
the `TRACK_CHANGED` notification to the `GetElementAttributes` reply
carrying the new title was ~16ms in the one instance traced (records
12763→12769) — negligible. That's only the Bluetooth-transport hop,
though; it does not cover how long the phone's OS took internally to
decide the track had "changed" after the app pushed a new title, nor how
long the MiniToo takes to redraw its screen after receiving the
attributes — neither is visible in a packet capture. Total perceived
end-to-end delay is unmeasured; would need a stopwatch against the real
screen, not another capture.

### Music Name display style (`0xBD 0x1C`) — decompile-only, NOT verified

A second, separate screen exists in the decompiled app under "Light" →
"Lyrics Display" (`LightLyricFragment.java`, string resource
`light_lyric_title` = "歌词显示"): a color picker (9 preset colors + a
custom color bar) and a scroll-speed slider, with **no free-text field**.
It sends a binary command, not JSON, within the already-known-safe
`SPP_DIVOOM_EXTERN_CMD` (`0xBD`) family this project already uses for
screen on/off (`0xBD 0x2F`):

```
0xBD 0x1C 0x00                                 -- get current config
0xBD 0x1C 0x01 <speed> <red> <green> <blue>    -- set style
```

(`0x1C` = 28 = `SPP_SECOND_SET_MUSIC_NAME_CFG` in the decompiled
`SppProc$EXT_CMD_TYPE` enum; the device can also send this same frame
type unprompted, per the app's own incoming-packet dispatch table, so a
`GetConfig`/state-push pattern like White Noise/Atmosphere likely applies
here too.)

Because there's no text field in this screen's UI, this most plausibly
configures the *display style* (color/scroll speed) for whatever title
text is already reaching the device by some other route (e.g. the AVRCP
mechanism above) — not a second way to deliver the text itself. **Not
capture-verified, not hardware-tested, and not even confirmed to be
reachable from the MiniToo's actual app UI** — this project has only
found it in decompiled code shared across Divoom's device catalog, and
per this project's own methodology, decompiled code alone has been wrong
before. Before ever sending `0xBD 0x1C` from this project's own code:
first check whether the official app even shows this "Lyrics Display"
sub-screen with the MiniToo connected, then capture it if it does.

## Device Settings (`Sys/SetConf`)

Miscellaneous device settings (notification-sound level, temperature unit,
date format, 24-hour clock, Bluetooth auto-reconnect, remember power-on
volume, auto power-off) turned out to share **one single JSON command** —
there's no per-setting opcode. Decoded from two real BT HCI snoop captures
(2026-07-06 and 2026-07-07, same methodology as Photo Album/Atmosphere) of
the official app toggling each setting back and forth.

**Gotcha hit during the second capture, worth remembering for the next
one:** a fresh reconnect reassigns L2CAP CIDs from scratch — the outgoing
JSON channel was `cid=76` in the first capture and `cid=65` in the second.
Scanning only the previously-known CID number found nothing new and looked
like the app's later actions weren't reaching Bluetooth at all; the real
traffic was sitting on a different CID the whole time. Always re-run the
parser's CID-count listing fresh per capture rather than assuming the
number from last time still applies.

### How the app actually does it

The app keeps one large local settings object (device config + a chunk of
account/location state) and re-sends the **entire thing** as a single
`Sys/SetConf` JSON command, over plain `SPP_JSON` (`0x01`), every time
*any one* field changes — full state, not a delta. Same "always resend the
whole object" pattern this project already uses for White Noise/Atmosphere,
just with a much bigger object (~35 fields). No `Sys/GetConf` was ever
observed in the capture — the app never explicitly reads the config back;
it just trusts its own cached local state and blindly overwrites the
device's on every change.

**Confirmed by direct hardware testing (2026-07-07): there is no
state-readback for this command at all**, unlike White Noise's
`WhiteNoise/Get` or Atmosphere's `Lyric/GetConfig`. Tested directly against
a real MiniToo from this project's own daemon: a plain `Sys/SetConf` write
gets no reply, and probing with an invented `Sys/GetConf` (a command the
official app never sends) also gets no reply, even waiting 5-6 seconds.
(An earlier reading of the daemon's rx log appeared to show the device
echoing full state unprompted, but that turned out to be stale log content
left over from a prior daemon session that hadn't been fully restarted —
a clean daemon restart plus one isolated test command produced zero
device-initiated traffic.) Consequence: this project's Device Settings
screen has no way to detect drift if a setting is changed from the
official app or the device's own physical controls — it can only remember
what it last sent (cached in `UserDefaults`, see Implementation below), not
read the device's true current state.

Also specifically checked: the original phone capture's lone
`Sys/DevUpdateConf` push (the one that looked like a spontaneous
connect-time state announce) sits chronologically right after the app's
first `Device/SetUTC` send, which raised the question of whether SetUTC
itself is the trigger. Tested directly: sending `Device/SetUTC` alone
against a freshly-restarted daemon connection produced no reply either.
Whatever actually triggered that one push in the phone capture — possibly
something specific to the official app's "add device" pairing flow, or
some other part of its multi-command startup burst (alarm list, tomato
list, clock info, etc. all fired in a tight sequence before it) — wasn't
isolated. Not a resolved "no-op query command" the way `WhiteNoise/Get`
or `Lyric/GetConfig` are; would need a capture specifically designed to
bisect the startup sequence to pin down further, and doesn't seem worth
the effort for what it'd unlock. The `(?)` tooltip on the Device Settings
screen tells the user this straightforwardly instead.

Wire-level, this JSON blob is long enough (~700 bytes) to exceed one RFCOMM
frame, so the official app splits it across two consecutive RFCOMM
writes with no application-level ACK/handshake between them (plain
transport-level fragmentation, not the chunked-transfer-with-ACK pattern
`0x8b`/Photo Album use). This project's own `DivoomRawFrame.build` +
daemon write path doesn't need to replicate that split manually — macOS's
`IOBluetoothRFCOMMChannel` fragments large single writes at the transport
layer on its own, so building one `Sys/SetConf` JSON frame (regardless of
size) and sending it as a single ordinary job is sufficient, the same as
every other JSON command in this codebase.

### Baseline object (captured, real values)

```json
{
  "AutoPowerOff": 0, "BluetoothAutoConnect": 0, "ColorTemp": 0,
  "Command": "Sys/SetConf", "DateFormat": 0, "DeviceAutoUpdate": 1,
  "DeviceId": 0, "DevicePassword": 0, "DisableMic": 0, "GyrateAngle": 0,
  "HighLight": 0, "Language": 0, "Latitude": 0, "LcdImageArray": ["","","","",""],
  "LocationCityId": 0, "LocationCityName": "", "LocationMode": 0,
  "LockScreenTime": 600, "Longitude": 0, "MirrorFlag": 0,
  "NotificationSound": 30, "OnOffVolume": 1, "ScreenProtection": 0,
  "ShowGrid1632": 1, "StartupFileId": "", "TemperatureMode": 0,
  "Time24Flag": 1, "TimeZoneMode": 0, "TimeZoneName": "", "TimeZoneValue": "",
  "Token": 0, "UserId": 0, "WhiteBalanceB": 100, "WhiteBalanceG": 100,
  "WhiteBalanceR": 100, "Wind": 0
}
```

(`DeviceId`/`Token`/`UserId`/`DevicePassword`/`Latitude`/`Longitude`/
`TimeZoneName`/`TimeZoneValue` shown zeroed/blanked above — the real
capture had the phone's own account/location values in these fields.
MiniToo has no WiFi/GPS of its own and every other already-implemented
JSON command in this codebase uses one fixed placeholder `DeviceId`/
`Token`/`UserId` trio that's confirmed to work against this device, so the
implementation reuses that same trio here rather than the account-specific
values seen in the capture. The rest of the fields — `ColorTemp`,
`GyrateAngle`, `MirrorFlag`, `WhiteBalance*`, `ShowGrid1632`, etc. — read
like settings for other Divoom product lines (lamps/light cubes, rotating
displays) sharing this same command across Divoom's whole catalog, same
situation as the "screen dir cfg" opcode documented above; left untouched
at their captured values as inert passengers rather than guessed at.

**Implementation approach:** always start from this exact baseline object,
override only the field(s) the user actually changed, and send the whole
thing — mirrors what the real app does, and avoids clobbering the fields
above with guessed values.

### Fields exposed in this project

- **`NotificationSound`** (int) — a *level*, not a boolean. Observed values
  30 → 54 → 13 during one on-device sound-level control being exercised a
  couple of times; range/scale not pinned down beyond "well under 100".
  Exposed as a 0-100 slider.
- **`TemperatureMode`** (0/1) — **confirmed by direct visual observation**:
  `0` = Celsius, `1` = Fahrenheit (user watched the on-device unit flip
  C → F → C while this field went 0 → 1 → 0).
- **`DateFormat`** (0-5, six values) — **confirmed by a second capture**
  cycling through all six in order and the user reading each on-screen
  label directly:

  | Value | Format |
  |---|---|
  | 0 | `yyyy-mm-dd` |
  | 1 | `dd-mm-yyyy` |
  | 2 | `mm-dd-yyyy` |
  | 3 | `yyyy.mm.dd` |
  | 4 | `dd.mm.yyyy` |
  | 5 | `mm.dd.yyyy` |

- **`Time24Flag`** (0/1) — **confirmed by direct hardware testing
  (2026-07-07)**: `1` = 24-hour, `0` = 12-hour, matching the field name.
  (Appeared in the first capture toggling on its own, 1 → 0 then later
  0 → 1 → 0, alongside settings the user deliberately toggled without
  this one being consciously exercised at capture time — the mapping was
  confirmed afterward by directly testing the control from this app's own
  UI and watching the device.)
- **`BluetoothAutoConnect`** (0/1) — **confirmed by the second capture**:
  observed 0 → 1 → 0 exercising the "Bluetooth Audio Reconnect" toggle.
  `1` = enabled, matching the field name and standard toggle convention
  (off by default, first tap turns it on).
- **`OnOffVolume`** (0/1) — **confirmed by the second capture**: "Remember
  power-on volume" observed 1 → 0 → 1 (already on by default from the
  first capture, user turned it off then back on this time). `1` =
  enabled.
- **`AutoPowerOff`** (int, six values) — **confirmed by the second
  capture**: cycled 0 → 30 → 60 → 180 → 360 → 720 → 0. Clean round minute
  values — `0` = off/never, then 30 min, 1 hr, 3 hr, 6 hr, 12 hr. On-screen
  labels for the non-zero values weren't read directly, but the numbers
  are unambiguous.

### Confirmed NOT sent over Bluetooth

Two settings on the same app screen — **"Shake Shake"** and **"Tap and
Play"** — produced **zero field change** across two `Sys/SetConf` resends
in the second capture, even though the user tapped them between the
`BluetoothAutoConnect` and `AutoPowerOff` sequences. The app fired its
habitual full-state resend (screen-interaction reflex) both times, but the
JSON payload was byte-for-byte identical before and after. Matches the
user's own observation live in the app: neither one triggered any kind of
save/sync indicator. These two are Android/phone-local settings (probably
gesture-to-launch-camera / NFC-ish tap features that live entirely in the
phone's OS, unrelated to Divoom's own device state) and are **not
implemented here** — there is nothing to send.

### Implementation

`tools/divoom_device_settings.py` — CLI with a `set` subcommand, always
starting from the baseline object above and overriding only the flag(s)
passed. Wired into Control Center as a "Device Settings" screen
(`DeviceSettingsModel`/`DeviceSettingsView` in `DivoomControlCenter.swift`):
a notification-sound slider, a Celsius/Fahrenheit segmented control, a
6-way date-format picker (real labels above), a 24-hour-clock toggle, a
remember-power-on-volume toggle, and a 6-way auto-power-off picker. Each
change re-sends the full baseline object with just that field overridden,
as a single native `DivoomRawFrame` job (same fire-and-forget fast path as
brightness/screen on-off). Since there's no real device readback (see
above), each control's last-sent value is cached in `UserDefaults` and
used to seed the UI on next launch — the screen says so explicitly, since
this is "last value this app sent," not a live device state query.

**Hardware-tested (2026-07-07):** temperature unit, date format, clock
format, Bluetooth auto-reconnect, remember-power-on-volume, and auto
power-off all confirmed working end-to-end from this app's own UI against
a real MiniToo. One MiniToo-side quirk found during testing, not a bug in
this app: **the device's own on-screen settings menu can show stale text
after a change sent from this app (or the official app) until you back out
and re-enter that menu on the device** — the setting itself takes effect
immediately; only the device's own menu redraw lags behind. Confirmed
across all of the above settings. Documented as a general callout in
README.md's Troubleshooting section and via a `(?)` tooltip (`.help(...)`
on a `questionmark.circle` icon next to the screen's title) on the Device
Settings screen itself — not an inline text block, which ate too much
vertical space for something most people only need to read once.

Several UI bugs found and fixed during this same hardware-testing pass:
- The notification-sound slider showed the same discrete tick-mark
  artifact seen previously on other sliders in this app — traced to
  passing `step:` to SwiftUI's `Slider`; removing it (rounding the value
  on read instead, same as the White Noise channel sliders already do)
  fixed it.
- The Control Center window stayed oversized (lots of empty space to the
  right) when switching from a wider screen (e.g. the icon grid) to this
  narrower one. Root cause: every detail screen is wrapped in
  `.frame(maxWidth: .infinity, ...)` so the resize logic could measure a
  consistent size across screens, but a plain `maxWidth: .infinity` child
  just accepts whatever width the window *already* is rather than
  reporting what it actually needs — so the window never shrinks back down
  once a wider screen has stretched it. Fixed by adding
  `.fixedSize(horizontal: true, vertical: false)` to each detail
  screen/the icon grid right where they're placed in `ControlCenterView`,
  forcing each one to report its own true intrinsic width regardless of
  the window's current size. Checked White Noise and the icon grid
  afterward for regressions — both still size correctly.
- The original stacked label-over-control layout (each row: label above,
  fixed-`200`pt-wide control below) produced uneven whitespace once rows
  with very different label lengths ("Notification Sound" vs "Bluetooth
  Auto-Reconnect") sat next to controls that didn't need that much width.
  Replaced with a `SettingRow` label+control-on-one-line layout (matching
  White Noise's per-channel row style) and switched the two-state
  Off/On settings from a stretched segmented control to a native
  `Toggle`/`.switch`, which is both more compact and more idiomatic macOS.
