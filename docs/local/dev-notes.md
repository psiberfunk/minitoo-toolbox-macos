# Dev notes (fork-local)

Not for upstream — personal working notes for developing this fork.

## Current code layout (fork-only, not all upstream yet)
- `tools/DivoomDaemon.swift` — standalone daemon binary, holds the actual
  `IOBluetooth` RFCOMM channel, JSON jobs over a local TCP socket.
- `tools/DivoomMenuBar.swift` — menu-bar app: daemon lifecycle, menu UI,
  `DivoomRawFrame` packet builder + native fast-path sender, device-address
  preference.
- `tools/DivoomControlCenter.swift`, `DivoomPreferences.swift`,
  `DivoomDeviceSetup.swift`, `DivoomAtmosphereIcons.swift` — SwiftUI
  windows, one `ObservableObject` model per screen. Several of these only
  exist on `personal`/open PR branches, not yet merged upstream.
- `tools/divoom_*.py` — Python CLI tools for features developed/tested
  that way.
- `tools/DivoomRFCOMM.swift` / `DivoomRFCOMMSend.swift` — standalone
  dev/debug scripts, not part of the shipped app.

## Decision: not rebasing on ztomer/divoom_lib
Zero mentions of "MiniToo" in its ~70K lines; its similarly-named "Timoo"
is a different, much lower-resolution product; its own white-noise routing
has the same wrong HTTP-only assumption already found and fixed
independently here. Its `bt_spp_rfcomm.py` transport is worth reading for
patterns if the daemon's RFCOMM robustness ever becomes a real pain point,
not worth adopting as a dependency.

## Dev/testing pace
Don't rapid-fire kill/rebuild/relaunch/send cycles against the real device
during a dev session — this can wedge the Mac's own Bluetooth stack
independent of any code change (symptom: every command reports success
while the device visibly does nothing). Check `ps -ef | grep blueutil` for
a stuck child before re-blaming the latest code change.

## Known gotchas (candidates for PROTOCOL.md/README.md, not yet promoted)
Rescued from the old chronological memory file before it was deleted;
still accurate, just not yet moved into the real repo docs — do that as a
deliberate, separate step, not bundled into unrelated work.

- **Panel is 160×128, not 128×128** — confirmed via hardware test with an
  asymmetric block header; square sends are left-justified from the
  top-left, not centered/letterboxed. → PROTOCOL.md.
- **Photo Album crash was from a discarded theory, not the real format**:
  an early decompiled-code guess (12-byte header + SiFli eZip) crashed the
  device twice; the real, capture-verified format is a 5-byte announce +
  plain JFIF JPEG under a simpler blob header — already in PROTOCOL.md's
  "Photo Album" section, nothing left to promote here.
- **Device rename (`0x75`, `SPP_SET_DEVICE_NAME`) — shelved, full story.**
  Protocol: body = 1-byte length prefix + raw UTF-8 name bytes, same raw
  single-opcode frame family as brightness/screen-on-off (not the JSON-
  over-BT family); the device never sends a reply to it. Found via APK
  decompile (`MoreBluetoothFragment.P2()` → `CmdManager.A0(str)` → opcode
  `0x75`, the opcode right after brightness `0x74`), then confirmed with a
  real capture. Implemented as `DivoomMenuBar.setDeviceName(_:)` plus a
  rename field in Preferences.
  Hardware-tested with a real Android capture once results got confusing
  (renamed via our tool to "HIPPO", then via the official app to
  "TESTB"/"TESTBB", power-cycling and re-scanning each time): the capture
  confirmed our implementation is byte-for-byte identical to the official
  app's wire bytes for both odd- and even-length names — ruled out any
  parity/length/framing bug on our side — and confirmed the device never
  sends any reply/ACK to this command, in either capture. Also corrected
  an earlier APK-only guess along the way: the `"Divoom MiniToo-Audio-"`
  broadcast-name prefix is **real device-side/firmware-reconstructed
  behavior**, not just an Android-app UI convention — the decompiled code
  only ever sends the typed suffix with no client-side prefix
  concatenation, but the prefix still reappeared in the device's actual
  broadcast name in the capture even though neither app ever transmitted
  it. Trust the hardware result over a code-only inference here if this
  ever comes up again (e.g. in device-scan/matching logic).
  **Unresolved real quirk**: after these tests, the device's own
  auto-reconnect kept broadcasting the earlier, truncated "...-HIPP" even
  after later legitimate renames via the official app. This looks like the
  Divoom app optimistically echoing its own last-sent value locally with
  no device readback (the same optimistic-UI pattern our own Preferences
  rename uses), rather than two separate BT endpoints disagreeing — but
  the root cause of the on-device persistence flakiness itself is still
  unknown; further diagnosis would need more invasive testing than is
  worth it for this feature's value right now.
  **Status**: parked per explicit user decision (2026-07-06). Code moved
  out of `personal` onto the `shelved/device-rename` branch (tip commit
  `15df6e9`) rather than kept live — revisit there if the persistence gap
  ever gets solved. Capture artifact:
  `~/Desktop/MiniTooProject/captures/rename-test.cfa.curf`.
- **Confirmed protocol dead ends**: general photo/gallery upload pollutes
  the device's own gallery and can't pin one image; `0xBE` fake-FileId
  custom-face path re-uploads on every switch (not actually instant);
  `0x8C` stored-animation slots never produced a device response. →
  PROTOCOL.md's existing dead-end/gap sections.
- **`IOBluetoothRFCOMMChannel` requires same-thread calls** — a
  background-thread `writeSync` silently "succeeds" while sending nothing;
  this is what the daemon's write-timeout fix (PR #11) actually works
  around. → PROTOCOL.md implementation notes.
- **`blueutil` aborts if run directly from an interactive shell** (a TCC
  quirk tied to the calling process) but works fine as a child of the
  signed `.app` — don't mistake this for a device problem. → README.md
  Troubleshooting.
- **Ad-hoc codesigning caused a fresh Bluetooth prompt on every rebuild**
  (TCC keys off the binary's CDHash) — already fixed via a stable signing
  identity (PR #9); the explanation just isn't written up in README yet. →
  README.md Troubleshooting.
- **The "double Bluetooth connect chime"** on a fresh daemon start is
  cosmetic (RFCOMM connects, then macOS separately auto-restores the A2DP
  audio profile ~2s later) — not a bug. → README.md Troubleshooting.
- **Battery status private-API details**: `CoreUtils.framework`'s
  `CUPowerSourceMonitor`/`CUPowerSource`, vendor/product ID 1494/10
  (decimal forms of Divoom's 0x05D6/0x000A), driven via the Objective-C
  runtime (`dlopen` + `NSClassFromString`, no headers exist). Filed as an
  Apple Feedback request for a public API, FB23587697.

## Legacy rescue, second pass
`project_divoom_minitoo.md` (the old memory file) is being kept as an
unindexed archive, not deleted — a second look turned up 3 more items
worth keeping here. This is the last planned rescue pass.

- **Daemon job protocol**: never bundle more than one packet into a single
  daemon job unless it's a genuine chunked transfer (image/GIF upload) —
  the multi-packet path assumes a request/ACK handshake that plain JSON
  commands never trigger, causing a false `ok:false` even though the
  packets sent fine (this caused a real bug in Atmosphere: `Lyric/Enter` +
  `Lyric/SetConfig` bundled together silently "failed").
- **`parse_btsnoop_rfcomm.py` needs ACL fragment reassembly**: a naive
  per-HCI-packet parser can misdecode a long reply's continuation fragment
  as a bogus extra L2CAP channel, hiding a real device reply entirely —
  reassemble by `(handle, direction)` using the ACL header's PB flag bits
  before treating a payload as a complete L2CAP frame.
- **Python subprocess argv gotcha**: a flag placed before the script path
  in a subprocess argv list (e.g. `[py, "--build-only", script, ...]`) gets
  parsed by Python's own interpreter, not the script — shows up as
  Python's own "Unknown option" usage error instead of the script's. Put
  the script path first, flags after.
