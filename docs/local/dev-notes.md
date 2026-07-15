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
  windows, one `ObservableObject` model per screen. These are maintained on
  this fork's `main`; upstream parity is not implied.
- `tools/divoom_*.py` — Python CLI tools for features developed/tested
  that way.
- `tools/DivoomRFCOMM.swift` / `DivoomRFCOMMSend.swift` — standalone
  dev/debug scripts, not part of the shipped app.

## Blueutil removal is feasible (researched 2026-07-10)

`blueutil` is not the MiniToo transport. The shipped Swift daemon already
uses the same macOS `IOBluetooth` framework directly to open RFCOMM channel
1. At the time of this research, the menu-bar app still shelled out to
`blueutil` for device inquiry, paired-device enumeration, pairing/name lookup,
connection-state checks, and disconnect/reconnect convenience actions.

Review of blueutil's source established that it is an Objective-C CLI wrapper
over `IOBluetooth`, not a privileged/Homebrew-only Bluetooth mechanism. Its
source calls out private `IOBluetoothPreference*` functions only for global
controller power/discoverability preferences; those are irrelevant here. The
per-device operations we use are the framework-level device inquiry/pairing
and connection APIs. In particular, its `--disconnect <MAC>` closes the
device-level Classic connection; native Swift should be able to perform the
same reset through the `IOBluetoothDevice` represented by that MAC before the
daemon opens RFCOMM.

This is a shippable-dependency cleanup candidate, not an assumption that the
MiniToo behavior has already been verified: implement it behind the existing
menu actions and hardware-test native disconnect → daemon RFCOMM-open before
removing blueutil. The device-level disconnect necessarily drops macOS audio,
which matches the present blueutil behavior and is the prerequisite observed
for reliable RFCOMM ownership.

### Migration status (2026-07-10)

Implemented in `tools/DivoomBluetooth.swift`; app code no longer invokes the
external CLI. Physical testing confirmed scan/pairing. The first implementation
mistakenly treated saved pairing records as scan results and omitted a
controller-power check; corrected code now labels nearby inquiry results and
saved records separately. Do not mark the migration fully hardware-verified
until nearby-unpaired discovery plus native disconnect → RFCOMM-open and audio
reconnect have been observed.

## Decision: not rebasing on ztomer/divoom_lib
Zero mentions of "MiniToo" in its ~70K lines; its similarly-named "Timoo"
is a different, much lower-resolution product; its own white-noise routing
has the same wrong HTTP-only assumption already found and fixed
independently here. Its `bt_spp_rfcomm.py` transport is worth reading for
patterns if the daemon's RFCOMM robustness ever becomes a real pain point,
not worth adopting as a dependency.

## Connectivity/status implementation record (2026-07-12)

Preserved from the former status tracker because these are implementation
constraints and debugging evidence, not current backlog items.

The menu must keep three independent signals separate:

| Signal | Establishes | Must not establish |
|---|---|---|
| Saved pairing record | Setup identity | Range, a live link, or control health |
| `IOBluetoothDevice.isConnected()` | Generic MiniToo Bluetooth link | A2DP availability, RFCOMM health, or another host's ownership |
| CoreAudio route match | Local route unavailable/available/selected/unknown | Control health or another host's connection |
| Daemon process state | Process lifecycle | A working device channel |
| Parseable `WhiteNoise/Get` reply | End-to-end local control health | Audio state or why a failed probe occurred |

`WhiteNoise/Get` is a capture-derived, hardware-confirmed read, so it is the
safe probe. A failed probe is reported neutrally as control unavailable; the
app cannot infer that audio is connected or identify another host using a
Bluetooth profile.

The current menu uses monochrome `×` for Bluetooth unavailable, `○` when
Bluetooth is on but MiniToo is not linked, `◐` for an incomplete link, and
`◆` only when all measured components are ready. In Ready it shows the three
independent rows—Bluetooth, Audio on this Mac, and Device control—plus battery;
it intentionally avoids redundant “Ready”/“Daemon running” rows. Routine
results stay out of the main menu; non-routine diagnostics appear as
`Latest status:` in Debugging Tools.

Two CoreAudio fixes matter if route detection regresses. Apple returns the
device-name `CFString` with caller ownership here, so the code must use the
correct retained ownership transfer rather than `takeUnretainedValue()`. Also,
two live CoreAudio objects can share the MiniToo name: treat them as one route;
the default output means **Selected**, otherwise any live match means
**Available**. A missing saved name or genuinely ambiguous match is **Unknown**;
a saved name with no live CoreAudio match is **Unavailable**.

The Bluetooth MAC remains the stable RFCOMM/link identity. The displayed name
is only a CoreAudio correlation hint and is refreshed from that saved MAC, so a
normal Bluetooth rename does not require rescanning.

Two state-machine errors were fixed. Probe-in-flight is independent of the
visible `Checking…` state, preventing startup from getting stuck; and stop/start
invalidates old callbacks before publishing the new lifecycle state. The only
top-level recovery action is contextual: start when stopped, retry when running
but unhealthy. Stop, restart, and generic-Bluetooth reset remain in Debugging
Tools because they can interrupt playback.

A real stale-RFCOMM launch showed that an existing daemon process is not proof
of a usable channel. Launch now preserves a healthy inherited connection. Only
when its first safe probe fails does it stop that daemon, close the generic
MiniToo Bluetooth connection once, and start a fresh daemon. A second failure
is reported without looping; menu-open probes never invoke that reset. Commit
`cb31991` contains the lifecycle/recovery correction. A fresh launch reaching
Ready and controlling brightness was directly observed; keep any broader audio
or automatic-recovery claim bounded to its own user observation.

## DMG Finder presentation record (2026-07-10)

Preserved from the former release notes because Finder behavior is easy to
rediscover expensively:

- `dmgbuild` creates `.background.tiff`. Users who enable Finder’s “show
  hidden files” can see it; a shipped DMG must not try to override that user
  preference.
- An off-canvas `.background.tiff` icon location expands Finder’s scrollable
  canvas, creating a scrollbar. Keep any fallback location inside the visible
  canvas instead.
- Finder window chrome and a small icon-view inset mean a background-sized
  `window_rect` can crop the artwork. The current layout includes measured
  headroom. A user-enabled Path Bar can still consume viewport space; that is
  an accepted Finder preference, not a DMG-controlled setting.
- The current committed DMG follow-up is `aed3e86` (icon alignment). Verify
  its published Finder appearance when a hosted build is available.

## Dev/testing pace
Don't rapid-fire kill/rebuild/relaunch/send cycles against the real device
during a dev session — this can wedge the Mac's own Bluetooth stack
independent of any code change (symptom: every command reports success
while the device visibly does nothing). Check `ps -ef | grep blueutil` for
a stuck child before re-blaming the latest code change.

## BT HCI capture workflow (tablet-side cleanup)
Recurring procedure for pulling a real BT capture (used for atmosphere,
device-settings, rename-test, lyrics-avrcp-test so far):

1. Quit the Mac daemon/app first — MiniToo only holds one BT connection at
   a time, and the Android device needs to pair for the test uncontended.
2. On the Android tablet: Settings → Developer Options → "Enable Bluetooth
   HCI snoop log" → on. This is a production/`user`-build device
   (`ro.debuggable=0`, no root) — `adb shell setprop
   persist.bluetooth.btsnoopenable true` fails with "Failed to set
   property", so this toggle must be flipped by hand in the UI, not
   scripted.
3. Do the test action on the tablet against the MiniToo.
4. Pull it: `adb bugreport <dest.zip>`, unzip, the capture is at
   `FS/data/misc/bluetooth/logs/*.cfa.curf` inside (btsnoop format despite
   the extension — this is an OEM-specific rotation/naming scheme, not
   stock AOSP's `btsnoop_hci.log`). Copy just that file into
   `captures/<name>.cfa.curf` following the existing naming convention.
5. **Turn the HCI snoop log toggle back off on the tablet.** Don't leave
   it on continuously. Reasoning: AOSP's snoop log is normally a bounded/
   rotating log so it *shouldn't* flood storage indefinitely, but this
   tablet uses a non-stock naming scheme (`.cfa.curf`, not
   `btsnoop_hci.log`) so its actual rotation/cap behavior is unverified —
   `adb shell ls -la /data/misc/bluetooth/logs/` returns "Permission
   denied" on this device even when connected (shell UID can't read that
   path directly; only `adb bugreport`'s elevated collection can). Since
   we can't confirm the cap, treat it as unbounded and toggle
   off-when-idle rather than trusting it. Off-by-default also keeps
   future captures smaller and easier to search (less unrelated BT
   traffic from other paired devices/background apps).

   **There's no direct way to delete/inspect the log file itself** —
   `rm`/`ls` on `/data/misc/bluetooth/logs/` both fail with "Permission
   denied" (bluetooth-UID-owned, not root, and this doesn't change whether
   the tablet is connected or not). If you ever suspect it's actually
   accumulating: (a) toggle the snoop log Developer Option off then back
   on, or (b) reboot the tablet — both force the BT stack to reopen the
   log file fresh, which is the closest thing to a "clear" available
   without root. Don't use Settings → Apps → Bluetooth → Clear storage as
   a fix — that risks wiping paired-device bonds (re-pairing the MiniToo
   and everything else), disproportionate for a log-size worry. To check
   whether there's an actual problem before reaching for either fix, use
   `adb shell df -h` (works fine even though the log directory itself
   doesn't — different permission scope) and watch the `/data` line's
   `Avail` trend over time; baseline as of 2026-07-07: 36G free / 26%
   used.
6. **Clean up the local Mac-side artifacts once analysis is done.** Each
   `adb bugreport` pull produces a `.zip` (10-15MB) and, once unzipped, an
   `_extracted/` directory (40-50MB) — both are working scratch, not
   referenced by any doc. Only the single `.cfa.curf` pulled out of them
   is ever cited from PROTOCOL.md/dev-notes.md. Once the capture's been
   analyzed and findings are written up, delete the `.zip` and
   `_extracted/` for that session and keep only the `.cfa.curf`:
   `rm -rf captures/<name>.zip captures/<name>_extracted/`. This is what
   took `captures/` from 123M down to 11M on 2026-07-07 (two stale
   zip+extracted pairs from atmosphere and lyrics-avrcp-test cleaned up
   after their docs were already written).

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

## Lyrics display on the Atmosphere/Lyric screen — CONFIRMED via capture (2026-07-07)

Confirmed the same day via a real BT HCI snoop capture
(`captures/lyrics-avrcp-test.cfa.curf`) — see PROTOCOL.md's "TextEffect/
lyric text" subsection for the full decoded mechanism (standard AVRCP
`GetElementAttributes`/`RegisterNotification`, Company ID `0x001958`, not
any custom Divoom command). The theory below is kept as-written for the
reasoning trail; treat PROTOCOL.md as the source of truth now.

### Original theory (2026-07-07, was unverified — now confirmed above)

Third-party AI research (Perplexity, not independently verified — treat per
`.claude/rules/protocol-reverse-engineering.md` until confirmed) surfaced a
theory that reconciles cleanly with what this project already found via
direct capture + decompile:

- This project's own capture/decompile work (PROTOCOL.md's Atmosphere
  section) already proved `Lyric/SetConfig` carries only `Background` +
  `TextEffect` indices — no text field exists anywhere in that JSON
  schema, and no code path in the decompiled app (checked `LyricModel`,
  `LyricSetConfigRequest`/`Response`, `DivoomNotificationListenerService`)
  ever populates lyric content into it.
- Perplexity's theory: real lyric text on Divoom devices (and other "BT
  lyric display" gadgets/car stereos) doesn't travel over any custom
  protocol at all — it rides the **standard AVRCP media-metadata fields**
  (Song Title/Artist Name, via `GetElementAttributes`) that any
  Bluetooth-audio-connected phone already broadcasts. Specific music
  players (QQ Music, NetEase Cloud Music, Kugou, and reportedly PowerAmp on
  Android via an "Automotive/Car Bluetooth Lyric" toggle) rewrite that
  metadata field in real time to the current lyric line instead of the
  real title; anything that displays "Now Playing" title text — including,
  theoretically, MiniToo's `Lyric/Enter` screen — would render it with zero
  Divoom-specific protocol work needed on our side.
- This would cleanly explain two things already observed: why `TextEffect`
  produced no visible change in the one hardware test done (no player had
  this toggle enabled, so no AVRCP title updates were happening); and why
  the JSON schema has no text field at all (text was never meant to travel
  over `SPP_JSON` — AVRCP is a different, standard BT profile, entirely
  orthogonal to the custom `0x01 SPP_JSON` channel this project has been
  capturing).

**Caveat, important**: the Perplexity answer's actual supporting citations
(Reddit threads) are about the Tivoo 2 and Ditoo Pro, not the MiniToo —
despite the query explicitly asking it to distinguish those. No source
directly confirms MiniToo's screen renders AVRCP title metadata as
scrolling text at all. Treat as an untested, well-reasoned hypothesis, not
a confirmed mechanism, until physically tested.

**Cheapest possible test (no new code, no capture, no protocol risk)**:
connect an Android phone to the MiniToo for audio as normal, put the
MiniToo into `Lyric/Enter` mode (the app's "Atmosphere" screen), enable a
"car/automotive Bluetooth lyric" toggle in a player that supports it
(PowerAmp has one; QQ Music/NetEase/Kugou reportedly have it natively),
play a track with local `.lrc` lyrics or the app's own synced lyrics, and
just watch the device screen. If nothing appears, the theory is dead and
`TextEffect` really is vestigial UI carried over from Divoom's WiFi-device
codebase. If something does appear, it's a genuinely new, zero-protocol
-risk feature to formalize — the "workflow" would likely just be "put a
phone in the right playback mode," no app code changes required at all.

### Open questions after the AVRCP capture (2026-07-07)

The AVRCP mechanism above is confirmed *a* working path, not proven to be
the *only* one, and three follow-up questions came out of reviewing it
with the user — full detail (including the raw opcode) is in PROTOCOL.md's
"Atmosphere" section, this is just the session-continuity pointer:

- **A second, decompile-only candidate exists**: `0xBD 0x1C`
  (`SPP_SECOND_SET_MUSIC_NAME_CFG`, inside the already-known-safe
  `SPP_DIVOOM_EXTERN_CMD` family) — a color+scroll-speed config under a
  "Light" → "Lyrics Display" screen in the decompiled app, with no
  free-text field of its own. Most plausibly configures *display style*
  for whatever title text is already arriving via AVRCP, not a rival text
  channel. **Not capture-verified, not hardware-tested, not even confirmed
  reachable from MiniToo's actual app UI.** Next step: check the official
  app for this tab with the MiniToo connected before touching this opcode
  at all.
- **Artist name confirmed not rendered** — the device only ever showed
  Title on screen during the test, even though `AttributeID=2` (Artist)
  was present in every captured response. Direct user observation, not an
  inference.
- **End-to-end delay only partially measured** — wire time from
  `TRACK_CHANGED` to the `GetElementAttributes` reply was ~16ms
  (negligible) in the one instance traced. That's only the BT-transport
  hop; total perceived delay also depends on the phone's own OS-internal
  timing and the MiniToo's on-screen redraw time, neither observable from
  a packet capture. Unmeasured — would need a stopwatch against the real
  screen.

### macOS-side lyric delivery — evidence and next tests (updated 2026-07-09)

User asked whether this app could hook Apple Music's currently-playing
synced lyric line on macOS and push it to the MiniToo via the AVRCP
mechanism above. Broken into two separate hard problems:

1. **Reading the current synced lyric line out of Apple Music**: not
   attempted this session, still open. Apple exposes no API for this at
   all. Music.app's AppleScript dictionary and the private
   `MediaRemote.framework` (what NowPlaying-style menu-bar utilities use)
   both give title/artist/elapsed-time, but not the specific line
   Music.app's own Lyrics panel is currently highlighting. Two candidate
   approaches, neither tried:
   - **Accessibility-API screen-scraping** of Music.app's Lyrics view
     (same mechanism VoiceOver uses) — would read exactly what Apple's UI
     shows, but unsupported/fragile, could break on any macOS/Music.app
     update.
   - **Reimplement sync ourselves**: read title/artist/elapsed-position
     (easy, scriptable) and independently fetch time-stamped lyrics
     (`.lrc`-style) from an external source, computing the current line
     from elapsed time locally. More robust/maintainable, but depends on
     a third-party lyrics source actually having the track — and pulling
     copyrighted lyric text from a third-party API is worth a legal-
     awareness gut-check before building on it, even for personal use.

2. **Pushing it to the MiniToo over AVRCP** — **tested directly this
   session, negative result; root cause not established.** Three escalating
   tests, all confirmed no visible change on the device (direct user
   observation each time):
   - A standalone Swift CLI binary setting `MPNowPlayingInfoCenter`'s
     `nowPlayingInfo` with no real audio session.
   - Same, but paired with a genuine (silent) audio stream via
     `AVAudioEngine`, routed to the MiniToo as the actual default output
     device (`SwitchAudioSource`, `brew install switchaudio-osx`) — ruling
     out "no active audio route" as the cause.
   - **Real Apple Music playback**, MiniToo set as the actual output
     device. Also nothing. This ruled out "our process isn't a
     legitimate media app" as the cause, since Music.app is about as
     legitimate as it gets.

   **One earlier lead from `log stream` (not a full packet capture):** macOS
   has its own
   proprietary Bluetooth Now-Playing-push mechanism —
   `audioaccessoryd`'s `BTSmartRoutingDaemon`, function
   `SendNowPlayingInfoUpdateToWx`. Captured while re-running the test:

   ```
   SendNowPlayingInfoUpdateToWx: 14:60:CB:BB:82:F6 ... BT_ERROR_NOT_CONNECTED
   SendNowPlayingInfoUpdateToWx: C4:35:D9:1D:9C:2A ... BT_ERROR_NOT_CONNECTED
   SendNowPlayingInfoUpdateToWx: BC:80:4E:AD:6C:DB ... BT_ERROR_NOT_CONNECTED
   ```

   The addresses matched paired AirPods. MiniToo did not appear in this
   Smart Routing log path, but that observation was not an AVRCP trace and
   does not establish macOS's metadata-routing policy.

   Reproduce: `log stream --style compact --predicate 'subsystem
   CONTAINS "bluetooth" OR subsystem CONTAINS "avrcp" OR process
   CONTAINS "bluetoothd" OR subsystem CONTAINS "MediaRemote" OR
   subsystem CONTAINS "nowplaying"'`, then trigger any NowPlayingInfo
   change while it's running.

   **Capture limitations:** this was one log correlation, not a byte-level
   AVRCP trace like the Android capture. We tried
   to get a real macOS-side capture via PacketLogger (part of Apple's
   "Additional Tools for Xcode") and hit a wall worth recording so it's
   not re-attempted blind:
   - PacketLogger recorded **zero** HCI/ACL packets even across a real,
     verified Divoom-audio-profile disconnect/reconnect cycle (done via
     the menu bar app's own Disconnect/Reconnect Audio items — real
     Bluetooth events, confirmed by the app's own status line changing).
   - Apple requires installing a separate diagnostics **configuration
     profile** before PacketLogger can see internal-radio HCI traffic at
     all (found via a forum post, then independently verified directly
     against `developer.apple.com/bug-reporting/profiles-and-logs/`,
     which really does host a `Bluetooth_macOS.mobileconfig` file plus
     instructions PDF — this is real Apple-documented behavior, not a
     rumor).
   - A correct macOS profile was later installed. PacketLogger authenticated
     and started but still recorded zero HCI/ACL packets during real activity.
     Do not infer that raw capture works from a successful authentication.
   - Even the *correct* macOS profile may not have fixed it anyway: its
     payload only configures `com.apple.system.logging` verbosity
     (`Level: Debug` for the `com.apple.bluetooth` subsystem) — i.e. it
     boosts `log stream`/`log show` detail, which is a **different**
     Apple diagnostic mechanism than PacketLogger's raw kernel-level HCI
     capture. Conflating the two cost real time this session.
   - **Current decision:** PacketLogger is not a usable packet-level source
     on this M3. Unified logs remain useful, but do not settle AVRCP frames.

   **2026-07-09 controlled evidence:**
   `~/Desktop/minitoo-avrcp-track-change.log` proved active A2DP and a
   MiniToo-originated Next Track command reaching Music.app, but contained
   no observed MiniToo `GetCapabilities`, `RegisterNotification`, or
   `GetElementAttributes` request after device-side and Music-side track
   changes. This points first at MiniToo/macOS AVRCP interoperability, not
   an established macOS metadata-filter policy. The leading, unproven
   hypothesis is SDP: the Mac Target advertises AVRCP `0x0106` / features
   `0x0011`; the Android tablet in the working capture advertises `0x0105` /
   `0x00d1` (including Browsing and Multiple Players).

**Bypass macOS's system AVRCP handling entirely and speak AVCTP/AVRCP
ourselves — TESTED 2026-07-07, the open-channel half works.** Since the
daemon already opens its own RFCOMM channel directly via `IOBluetooth`
(bypassing any OS-level SPP abstraction — see "Current code layout"
above), the same pattern applies here: `IOBluetoothDevice
(addressString:).openL2CAPChannelSync(&ch, withPSM:, delegate:)` can
open an arbitrary PSM directly, including PSM `0x17` (AVCTP, protocol ID
`0x110E`, confirmed from the Android capture).

Built a minimal standalone probe (`IOBluetoothDevice(addressString:
"B1:21:81:6F:4D:F0").openL2CAPChannelSync(&ch, withPSM: 0x17,
delegate:)`), packaged as a signed `.app` bundle with
`NSBluetoothAlwaysUsageDescription` in its `Info.plist` — a **bare**
Mach-O binary crashes immediately on any IOBluetooth call
(`TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION`, confirmed via the crash's
`.ips` report in `~/Library/Logs/DiagnosticReports/`); it must be a
proper bundle, and must be launched via `open`/LaunchServices, not
exec'd directly, or the same TCC crash recurs even with a correct
`Info.plist` present. Resolved the "biggest open unknown" from before:

- **Divoom audio profile connected** (macOS's own Bluetooth Audio stack
  already owns the AVRCP channel for that connection): `openL2CAPChannelSync`
  fails immediately, `ret=0xe00002bc` (`kIOReturnError`, generic IOKit
  failure).
- **Divoom audio profile disconnected first** (same precondition the
  daemon already requires for RFCOMM — see `openRFCOMM()`'s error
  message in `DivoomDaemon.swift`): **succeeds**, `ret=0x0`. And within
  milliseconds, unprompted, the MiniToo pushed a real AVRCP
  `GetCapabilities(EVENTS_SUPPORTED)` request over the new channel — see
  PROTOCOL.md's `TextEffect`/lyric-text section for the full byte
  decode. Same protocol, same Company ID (`0x001958`) as the Android
  capture, confirmed independently against the Mac.

**Tradeoff, not yet resolved**: this only works with audio disconnected
— no real Mac-sourced audio plays through the MiniToo while our own
AVCTP channel is open. Pushing custom text this way and playing real
audio from the Mac at the same time are currently mutually exclusive;
we never got to test whether that's a hard OS limitation or just needs
a different sequencing (e.g. open our AVCTP channel first, *then* see
if A2DP can still be separately negotiated afterward — untried).

**Not yet built**: only received `GetCapabilities` so far — never sent
a reply. To actually push custom title text, still need to: answer
`GetCapabilities` (`EVENTS_SUPPORTED` bitmask including
`TRACK_CHANGED`), answer `RegisterNotification(TRACK_CHANGED)` with
`INTERIM` then later `CHANGED` when we want to push a new title, and
answer `GetElementAttributes` with our own Title string — all modeled
directly on the Android capture's decode in PROTOCOL.md. Zero brick
risk — AVRCP/L2CAP is a generic Bluetooth Classic profile, unrelated to
any Divoom opcode. Probe code lives only in scratch right now (not
committed to the repo) — would need a proper home in `tools/` if this
gets built out further.

**Private SDP routes, assessed—not implemented:** `bluetoothd` has private
Classic XPC operations to add/remove client-owned SDP records, but no
update/replace operation was found; occupied PSMs are reassigned. Thus an
app cannot alter bluetoothd's existing AVRCP record on PSM `0x17`. Patching
the daemon's record-creation logic could test the SDP hypothesis while
preserving system audio/control, but on this SIP-protected arm64e Mac it
requires a deliberately weakened disposable macOS installation and is not a
product path. Do not patch the working Mac.

**Product decision (2026-07-10): shelved for now.** Do not pursue live lyric
delivery from a Mac while that Mac's audio plays through MiniToo. Public
Now-Playing tests were physically negative; direct AVCTP conflicts with the
active audio-owned AVRCP channel; private SDP mutation cannot change
bluetoothd's system record; and a daemon patch is not shippable. A Linux
bridge/proxy or Android companion could bypass those constraints but is
outside the accepted product scope. Therefore, do not spend time on the Dell
SDP experiment or further sniffing solely for this feature: they may explain
the interop failure, but cannot produce an acceptable product outcome.

Revisit only if macOS exposes a supported way to provide AVRCP Target
metadata, or if a MiniToo/macOS update materially changes the observed
behavior. Atmosphere configuration remains a complete, safe feature; only
live lyric delivery alongside MiniToo audio is shelved.

## Legacy rescue, second pass
`project_divoom_minitoo.md` (the old memory file) was kept as an unindexed
archive for a while rather than deleted outright — a second look turned up
3 more items worth keeping here. That was the last planned rescue pass;
the file itself was deleted 2026-07-11 once this rescue was confirmed
complete and the file was confirmed stale (a memory/documentation
structure audit found it described long-superseded states as current).

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

## Full-screen send regression: root-cause methodology (2026-07-10)

Diagnosed the "Full-screen (160×128) send crashes the device on the frozen
build, worked before" report by elimination, per this project's
capture/verify-before-claiming standard, rather than guessing:

1. Byte-diffed the actual encoder output. Checked out `tools/send_divoom_image.py`
   from `5457c83` (the commit whose message claims direct hardware
   confirmation of full-screen sends) into a scratch copy, ran
   `build_payload()`/`build_packets()` from both that version and current
   `HEAD` against the same synthetic 800×600 test JPEG at 160×128, and
   compared the resulting payload/packet bytes directly in a Python REPL.
   **Identical, byte-for-byte** (61460-byte payload, 242 packets, both
   versions). This rules out any encoding-side regression (zstd params,
   block-header bytes, chunking) for still images; the only textual diff
   between those two file versions is the unrelated `DIVOOM_FFMPEG`
   bundled-binary lookup in the video path, which a still-image send never
   executes.
2. Diffed `tools/DivoomDaemon.swift` (the process that actually writes
   RFCOMM bytes) across the same range — untouched since `8fd8615`
   (2026-07-06, a MAC-address-only change), well before the packaging
   commit. Ruled out the daemon's chunking/delay/ACK-wait logic.
3. That left exactly one behavioral change in the full-screen send path
   between the hardware-confirmed commit and the quarantined state: commit
   `a42c7b8` switched `ControlCenterModel.send()` from re-running the full
   Python pipeline (which rebuilds the packets file fresh immediately
   before sending) to resubmitting the packets file already written during
   the earlier preview (`--build-only`) pass, via the native
   `DivoomRawFrame.submit`. Re-reading that code path found the actual bug:
   `divoom_send.py` names its output `*-packets-lenpref.bin` from the
   media's filename stem alone, with no per-invocation uniqueness. Toggling
   "Full Screen" (which calls `buildPreview()` again) shortly after picking
   a file — before the first `buildPreview()` call's `divoom-helper`
   process has finished writing — starts a second build that writes the
   *same* output path underneath the first, and a stale completion handler
   arriving out of order can leave `packetsPath` pointing at a
   torn/mismatched file relative to what `previewImage` shows. A corrupted
   packet stream reaching the daemon is a plausible, sufficient explanation
   for "no final ACK, device visibly crashed."
4. This race predates the PyInstaller freeze (the file-naming bug existed
   the whole time `buildPreview()` has worked this way), but freezing
   `divoom-helper` as a `--onefile` PyInstaller binary meaningfully widened
   the window: onefile bootloaders self-extract to a fresh temp directory
   on every launch, adding real per-run startup latency that plain
   `python3 script.py` never had — long enough for a normal, fast
   pick-file-then-toggle-fullscreen user action to land inside a still-running
   first build far more often than before. This is consistent with (without
   being direct proof of) the reported before/after behavior change.

**Fix**: `ControlCenterModel` now tracks a `buildGeneration` counter, gives
each `buildPreview()` call its own generation-numbered output subdirectory
(so two concurrent builds can never share a path), and ignores any
completion whose generation doesn't match the latest one. The "Full Screen"
toggle is re-enabled in `SendMediaView`.

**Hardware result (2026-07-10):** user tested directly on the physical
device — still image and MP4/video, both full-screen and default
128×128, all four combinations sent and displayed correctly, no crash (all
had failed at full-screen before this fix). Confirmed fixed in practice.

**Open honesty about root-cause confidence:** before testing, the user
pushed back that their own recollection of triggering the original crash
was just "load one file, click Send once or twice" — no toggling, no
reselecting media. `send()` alone never calls `buildPreview()` again, so
that exact sequence doesn't obviously exercise the concurrent-build race
above. The fix demonstrably resolved the crash across a real multi-trial
test, but given the mismatch with the recalled repro, treat this as
fixed-in-practice rather than a fully-explained root cause. The next-best
suspect if this ever regresses again: transfer-duration sensitivity in
`DivoomDaemon.swift`'s RFCOMM write path (`sendPacket`'s hardcoded 2s
stale-write timeout per chunk) — full-screen is ~25% more data/packets
than default, i.e. a longer transfer with proportionally more chances to
hit that timeout or an ordinary Bluetooth hiccup mid-stream. Worth adding
duration/chunk-index logging around that timeout the next time this is
touched, so a future recurrence has real telemetry instead of another
round of guessing.

**Follow-up observation (2026-07-11), during the native-media-pipeline
port below:** one single, non-reproducible crash on full-screen MP4 send
(not still image) during the consolidated hardware test of the native
Send Media/Photo Album/custom-face ports. Did not reproduce across
several retries after a device reboot, and did not occur on default
128×128 video or on any still-image case. Deliberately not chasing this
with a code change — the exact suspect flagged above (RFCOMM write-timeout
sensitivity scaling with transfer size/duration) fits a single unreproduced
event on the single largest payload class this app sends far better than
a deterministic bug, and `DivoomDaemon.swift`'s RFCOMM-sending code is
completely unchanged by the native-pipeline port (only *how the packet
file gets built* changed, not how it gets sent — the built payload was
independently verified correct via round-trip decompression for this
exact case). Noting for the record only; revisit if it recurs with an
actual reproducible pattern.

## Phase 5: removing the Python/PyInstaller bundling infrastructure (2026-07-11)

Once all four native ports above were hardware-confirmed, deleted the
now-unused packaging around them:

- `tools/build-divoom-app.sh`: removed the `for FROZEN_TOOL in
  divoom-helper` copy block and the `.venv`-bundling fallback
  (`ditto "$ROOT/.venv" "$RESOURCES/.venv"` etc.), and the `cp
  "$TOOLS/divoom_*.py"` lines that copied Python scripts into
  `Resources/tools`. FFmpeg bundling is untouched (`build/ffmpeg/ffmpeg`
  still gets copied in) since it's still directly invoked by
  `DivoomProcess.swift`.
- Deleted `tools/freeze-python-tools.sh` and `tools/divoom_helper.py`
  outright (the PyInstaller onefile entry point and its build script) --
  nothing references them anymore.
- Deleted `requirements-build.txt` entirely (not just the `PyInstaller`
  line) -- once the CI workflow's venv-creation/freeze steps were removed,
  nothing referenced this file at all.
- The then-active release workflow: removed the `build` job's
  `setup-python`/`.venv` creation/`requirements-build.txt` install/
  `freeze-python-tools.sh` steps. The separate `release` job's own
  `setup-python` + `requirements-release.txt` (for `dmgbuild`, a CI-only
  DMG-packaging tool never bundled into the app) is untouched.
- Removed the now-dead `pythonExecutable()`/`runPythonTool()` functions
  from `DivoomMenuBar.swift` (confirmed via grep: zero remaining call
  sites after all four ports), and the `DIVOOM_FFMPEG` env-var injection
  in `run()` (also dead -- nothing reads that env var anymore now that
  Swift invokes ffmpeg directly via its own resolved path instead of
  handing it to a Python subprocess through the environment).
- Added a zstd entry to `THIRD_PARTY_NOTICES.md` (BSD-2-Clause,
  compression-only subset) alongside the existing FFmpeg entry.
- Updated `README.md`'s Requirements/Integration API sections: Python is
  now scoped explicitly to the kept standalone dev-CLI tools, not the
  shipped app; the old Integration API example (`.venv/bin/python` +
  `divoom_send.py` from inside the installed `.app`'s `Resources` folder)
  no longer works since the bundle contains no Python at all, so it now
  points at running the dev-CLI copy from a checkout of this repo instead.
- **Kept, per an explicit user decision (not the default assumption):**
  `tools/divoom_send.py`, `tools/divoom_clock.py`, `tools/divoom_album.py`,
  `tools/send_divoom_image.py`, `requirements-app.txt`, and `.venv` all
  remain in the repo as standalone dev-CLI/protocol-debugging tools --
  this project's own reverse-engineering methodology leans on scripts
  exactly like these. They are simply no longer referenced by
  `build-divoom-app.sh` or bundled into the `.app`.

Verified: a full clean local universal build (arm64+x86_64) after all
deletions produces an app bundle containing no `.py` files, no `.venv`,
and no `divoom-helper` anywhere (checked directly with `find`) -- only
`AppIcon.icns`, `PROTOCOL.md`, the bundled `ffmpeg` binary, and
`divoom-daemon`. Bundle size dropped to ~28MB (previously inflated by a
PyInstaller onefile blob plus a full `.venv` site-packages tree). App
launches and daemon starts cleanly post-deletion.

## Control Center window-sizing fixes (2026-07-11)

Fixed the Control Center window getting stuck at a stale size when
switching between panes of very different sizes (e.g. Atmosphere →
Send Media left a large dead-space gap on the right and/or bottom).
Found via user-reported screenshots, root-caused by re-reading the
actual `DivoomControlCenter.swift` view hierarchy rather than trusting a
stale in-code comment, and verified via live UI automation (System
Events/`cliclick`), not screenshots alone -- per
`.claude/rules/ui-testing-technique.md`'s carve-out that pure layout
checks don't need physical-device confirmation.

Two compounding bugs, found in two rounds (the first fix looked complete
until the user's follow-up screenshots showed width was *still* wrong):

1. **Round 1**: a greedy `.frame(maxWidth: .infinity, maxHeight:
   .infinity, alignment: .topLeading)` wrapped each pane's content,
   sitting *between* that content's `.fixedSize()` and the
   `GeometryReader` driving the window resize (`sizesControlCenterWindow`).
   A greedy frame like this reports its own size upward as whatever was
   *proposed* to it, not its child's true size -- so once the window grew
   for a big pane, every subsequent pane's reported size was just the
   window's own stale size fed back to it, in both dimensions. Fixed by
   deleting the two greedy frames and changing `.fixedSize(horizontal:
   true, vertical: false)` to `.fixedSize()` (both axes) on
   `detailView(for:)`/`functionGrid`.
2. **Round 2**: after Round 1, height reliably shrank but width still
   didn't -- caught because the user tested with real screenshots after
   visiting Photo Album (genuinely wide content) rather than trusting my
   first "looks fixed" claim. Root cause: a plain `Divider()` between
   `DeviceControlsBar` and the active pane sits in the *outer* root
   `VStack`, which had no `.fixedSize()` of its own. A bare `Divider()`
   has no intrinsic width -- it always echoes back whatever width its
   parent proposes, which was still the window's stale frame. Fixed by
   adding `.fixedSize()` to the outer root `VStack` itself, so the
   Divider (and anything else at that level) resolves against the
   subtree's true ideal size instead.

Also wrapped Photo Album's long one-line description text
(`.frame(maxWidth: 436, alignment: .leading)` +
`.fixedSize(horizontal: false, vertical: true)`) so it no longer forces
the whole window wider than every other pane just to fit on one line --
that was the trigger that made Round 2's bug visible in the first place.

Verified across every pane, round-tripping through the Functions grid
each time: Send Media (true width 476pt, previously misreported as 594
by coincidence), White Noise (398pt), Custom Faces (365pt), Photo Album
(635pt before the text wrap / 476pt after), Atmosphere (365pt -- its
background grid uses fixed 36pt columns, not adaptive, so it's actually
one of the narrower panes once measured correctly), Device Settings
(365pt). Pushed and monitored the release build to a green terminal
result both rounds.

## First unit test suite (2026-07-11)

Added `Tests/DivoomMiniTooTests/` (Swift Testing, `import Testing`/`@Test`/
`#expect`) via a new `.testTarget` in `Package.swift` depending directly on
`DivoomMiniToo` (`@testable import`) -- no refactor of the pure-logic
files into a separate library target, since an executableTarget works
fine as a `@testable import` target already. 28 tests, all passing,
covering only the pure/deterministic logic layer (no I/O, no Bluetooth, no
UI): `DivoomRawFrame.build`'s checksum/envelope framing, `DivoomChunkedUpload.packets`'
announce+chunk layout, `DivoomClockFrame`'s shortcut resolution and JSON
frame body, `DivoomAlbumEncode.buildPhotoBlob`'s header layout,
`DivoomMediaEncode.normalizeDims`/`animationPayload`'s validation and
header self-consistency, and `DivoomZstd.compress`'s magic-byte/determinism
properties (no round-trip decompress test possible -- only
`lib/common`/`lib/compress` were vendored from zstd, no `lib/decompress`,
confirmed via `ls tools/vendor/zstd-1.5.7/lib/`).

SwiftUI views/view-models and anything IO/Bluetooth/hardware-facing
(`DivoomControlCenter.swift`, `DivoomDaemon.swift`, `DivoomBluetooth.swift`,
ffmpeg subprocess spawning, battery log-scraping) are explicitly out of
scope for this pass -- they stay covered by the existing manual/hardware
testing discipline, not replaced by it. Run via `swift test` from the
package root; this is separate from `tools/build-divoom-app.sh`, which
only builds the two app products via `--product` and is unaffected by the
new test target (verified: still builds clean after this change).

**Caught a real doc bug while sourcing oracle data for these tests**:
PROTOCOL.md's `0x8b` announce-packet worked example (captured payload
length 11937) showed checksum bytes `ae 01`, but running the exact
`frame()` reference algorithm documented immediately above it against the
same cmd/body produces `62 01` instead -- a transcription slip in the doc,
not a code bug (the app's own hardware-confirmed sends already use this
same algorithm). Fixed in PROTOCOL.md with a note explaining the
correction. Lesson: even this project's own internal docs need the same
"verify before trusting" treatment as external sources when the value
matters (here, as unit-test oracle data) -- see
`feedback_verify_official_claims.md`.

**CI wiring added same day**: a `test` job in the release workflow checks out
the repo and runs
`swift test`; the `build` job now declares `needs: test`, so a failing
test blocks the release build/publish steps instead of only being
visible to whoever happens to run `swift test` locally before pushing.

**Strengthened same day, prompted by the user asking whether the tests
were "lipservice" or actually catching things**: added a property-based
test (`reconstructsOriginalPayloadAcrossManySizes`) that reconstructs the
original payload from chunk bytes across ~16 payload sizes (0-600), not
just the 2-3 hand-picked boundary cases already covered -- a much
stronger correctness guarantee for `DivoomChunkedUpload.packets`. Also
found and fixed a real latent bug while doing this: `chunkSize <= 0`
never advanced `offset` and would hang forever; not reachable from any
current call site (both real callers use the default), but now clamped
to `max(chunkSize, 1)` with a regression test. Also added
`DivoomImageResizeTests` covering `DivoomImageResize`'s cover-crop/resize
math and alpha-stripping (`coverResize`/`rgb24Bytes`), which had zero
coverage before this -- synthetic in-memory/temp-file images, no fixture
files or device involved.

**Zstd round-trip decompression added same day**, closing the one real
gap in the initial test pass (compression tests could only check magic
bytes/determinism, not that compressed data actually decompresses back to
the original bytes). Vendored `tools/vendor/zstd-1.5.7/lib/decompress/`
(4 `.c` files from the same official v1.5.7 release tarball already used
for `lib/common`/`lib/compress` -- re-downloaded and diffed to confirm
byte-identical provenance) and made `CZstd` a direct `DivoomMiniTooTests`
dependency so the test file can call `ZSTD_decompress` itself; production
code (`DivoomZstd.swift`) still only ever compresses. Deliberately did
not vendor `lib/decompress/huf_decompress_amd64.S` (x86-64 BMI2 assembly
fast path) -- defined `ZSTD_DISABLE_ASM` instead so both architectures
use the portable C decode path, avoiding an arch-conditional assembly
file in a universal build for a path that's only ever exercised by tests.
Confirmed via the vendored source itself (`portability_macros.h`) that
this macro has zero effect on `lib/compress`.

**Measured, not assumed, the shipped-binary size impact**: stashed just
these changes (leaving an unrelated concurrent session's supply-chain
security review docs untouched via exact-path `git stash push -- <paths>`,
same technique as the earlier Codex episode), did a clean `swift build -c
release --product DivoomMiniToo` before and after -- **byte-identical
size both times** (2,062,368 bytes). The linker's dead-code stripping
fully eliminates the unreferenced decompress object code from the actual
shipped app; it only ever gets linked into the test binary, which never
ships. `THIRD_PARTY_NOTICES.md` updated to reflect that decompress is now
vendored (test-only) rather than stating it's excluded.

## Untangling a concurrent session's accidental commit (2026-07-11)

Right after the zstd-decompress work above, a routine `git status` check
turned up something unexpected: the working tree was already clean and
`personal` already matched `fork/personal`, even though nothing had been
committed via an explicit `git commit`/`git push` from this session. Two
commits had appeared (`4572dfc`, `eeb9c05`), already pushed, authored
under the repo's normal git identity. Diagnosis: a concurrent Codex
session (working on a separate supply-chain security review) had run a
broad `git add`/commit at some point and swept up this session's
in-progress, uncommitted zstd-decompress edits (`Package.swift`,
`THIRD_PARTY_NOTICES.md`, `DivoomZstdTests.swift`, the vendored decompress
source) into the same commit as its own `docs/local/status.md`/
`docs/local/security-supply-chain-plan.md` changes -- two unrelated
workstreams bundled into one commit with a combined, half-accurate
message.

Nothing was actually lost or corrupted (diffed every file against what
had actually been written; ran the full local test suite, the real
`tools/build-divoom-app.sh` production build, and confirmed the CI runs
those pushes triggered were green) -- the only real damage was commit
attribution/organization, not content.

**Fix**: split the mixed commit back into three clean, correctly
attributed commits, using a temp branch from the last known-clean commit
(`git branch personal-rebase-tmp 20b6f41`), selectively restoring each
commit's own files from the mixed commit
(`git checkout 4572dfc -- <exact paths>`) into separate commits, plus a
clean `git cherry-pick` for the one commit that was already
single-purpose. Before touching `personal`, verified the split branch's
final tree was byte-identical to the original mixed history
(`git diff eeb9c05 personal-rebase-tmp` -- empty output confirms a pure
reorganization, no content drift) -- only then moved `personal` to the
new tip and force-pushed, using `--force-with-lease` (re-fetching to
confirm the remote hadn't moved again right before pushing) so it would
fail safely instead of clobbering anything if the concurrent session
pushed again in the meantime. The force-push itself required the user to
explicitly say "force push" -- a vaguer "yes, fix it" was correctly
rejected by the environment's own safety classifier as insufficient
consent for rewriting shared, already-pushed history.

Sent the concurrent session (Codex) a clear handoff message: what
happened, that its own supply-chain content was preserved intact just in
its own commit now, that its local view of `personal` is now stale (it
should `git fetch`+reset to the new tip rather than pushing again from
the old one), and a suggestion to scope any auto-commit behavior to
specific paths rather than a broad `git add -A`/`git commit -a` given
this working tree is sometimes shared with other concurrent sessions.
See `branch-workflow.md`'s "Concurrent sessions in the same working tree"
section for the general pattern this now lives under -- it covers both
this (detecting and untangling an already-committed-and-pushed
entanglement) and the earlier, distinct lesson (stashing another
session's uncommitted WIP before it interferes).

## Official Android app firmware-offer investigation (2026-07-12)

**Question:** why is a MiniToo on 343006 not being offered 343008 by the
official Android app? The locally connected reference MiniToo reported 343008;
the goal was to understand the friend's 343006 offer path, **not** to invoke an
update or transfer firmware.

### Live evidence (server-side, not Bluetooth)

Used the user-authorized Android Debug Bridge connection to the Lenovo Tab M9
and a short-lived, local HTTPS diagnostic proxy. The app's permissive custom
trust manager accepted the proxy certificate; no CA was installed on Android.
The proxy was enabled for 15 seconds only, then cleared and the app relaunched
normally. No firmware dialog was accepted and no device firmware-transfer
opcode was sent. Captured flows and any account-bearing payloads remain
outside the repository and must not be committed.

The official app (3.8.22) made both of these successful requests for the
connected MiniToo's hardware family:

- `Device/GetUpdateFileList`: request `HardwareList=[343]`, `IsTest=0`;
  response `ReturnCode=0`, `VersionList=[343000]`.
- `GetUpdateFileV3`: request `Hardware=343`, `IsTest=false`,
  `UpdateFlag=2`; response `ReturnCode=0` **but no firmware `FileId` or
  candidate `Version`**.

The official APK's `UpdateFileService` code corroborates the interpretation:
the `GetUpdateFileV3` request sends the hardware family (the device version
divided by 1000), not the current full version. If a response contains a file,
the app then compares the returned candidate version with the full version it
has already read from the speaker over Bluetooth. An absent `FileId` is filtered
out before that comparison, so there is no update to offer regardless of
whether the actual speaker is 343006 or 343008.

### Current conclusion and safe next step

As observed on 2026-07-12, Divoom's live international endpoint was not
publishing a downloadable firmware candidate for hardware family 343 in this
app/account context. This directly explains why changing only the local device
version cannot make the official app offer 343008: that version is not part of
the server response at all. The `VersionList` value alone is not a downloadable
firmware offer.

The request also carries account/device context, so this observation does not
prove that every account or region receives the exact same response. The next
definitive comparison, if needed, is a similarly short, redacted capture from
the friend's real 343006 setup. Do **not** fabricate a successful response or
attempt a firmware transfer merely to test UI behaviour: that would require a
valid firmware file and can create an unsafe device-update path. A genuine
server candidate (or a separately acquired, verified firmware package and
device-specific update protocol capture) is required before any update work
can be considered.

## Android HCI capture batch: time and timer tools (2026-07-12)

Fresh official-app HCI snoops were collected with the Mac daemon stopped so the
Android tablet owned the MiniToo RFCOMM connection. HCI snooping was disabled
again after each batch. Local-only captures are `../captures/time-sync-2026-07-12.cfa.curf`,
`../captures/tool-views-2026-07-12.cfa.curf`, and
`../captures/countdown-pause-2026-07-12.cfa.curf`; bugreport ZIPs remain
temporary and are not repo artifacts.

- **Time sync:** the official app again emitted normal SPP JSON
  `Device/SetUTC` immediately after connecting, with Unix seconds plus the
  host-local `yyyy-MM-dd HH:mm:ss` time. This corroborates the existing
  implementation plan. The physical clock was already correct, so this is
  capture-confirmed submission, not a new visual proof of clock correction.
- **Stopwatch:** captured entry, Start, Stop, and Reset in the official app.
- **Scoreboard:** captured entry, a score increment, reset confirmation, and
  confirmed return to `000`–`000`.
- **Countdown:** the duration picker must be given a nonzero time; confirming
  a one-minute duration immediately starts it (the app changes Start to Stop).
  The app-side Stop ends/resets the timer; it offers no pause control. The user
  directly confirmed the MiniToo's physical pause/resume control exists.

The physical countdown pause/resume was separately captured while the official
app was connected. No obvious plaintext pause event appeared, but that is not
enough to call it device-local: these snoops contain fragmented RFCOMM frames
and need stream reassembly before drawing a protocol conclusion. Do not invent
or transmit a pause command. For the eventual macOS Countdown UX, match the
official app's captured, safe surface first (set duration, start, end/reset)
and keep physical pause unsupported unless a capture-derived packet is found.

### Timer packet decode follow-up

`tools/parse_divoom_spp.py` was extended to read raw Android
`.cfa.curf`/btsnoop input (HCI ACL + L2CAP + RFCOMM UIH reassembly) while
retaining its prior TSV mode. Running it against the pause capture recovered
the tool protocol directly:

- tool reads: SPP command `0x71` (`SPP_GET_TOOL_INFO`), body `[tool]`;
  Countdown is tool `3`.
- tool writes: SPP command `0x72` (`SPP_SET_TOOL_INFO`); Countdown body is
  `[3, active, minutes, seconds]`. A one-minute start was
  `[3, 1, 1, 0]`; ending it was `[3, 0, 1, 0]`.
- The MiniToo replied to the read with a state payload containing tool `3`,
  active `1`, minutes `1`, seconds `0`, and acknowledged writes.

This is sufficient to implement and test the official-app-equivalent
Countdown surface. The physical pause/resume test produced alternating
Countdown write/ack traffic, but the capture does not isolate a distinct
device-originated pause packet from the surrounding app synchronization.
Pause remains intentionally unsupported until a cleaner, timestamped capture
establishes a standalone device event or command.

### Stopwatch reset decode follow-up

A clean, post-reboot Android HCI capture isolated the official app's three
Stopwatch tool-0 writes, each acknowledged by the MiniToo:

- Start: `0x72 [0, 1]`
- Pause: `0x72 [0, 0]`
- Reset: `0x72 [0, 2]`

The reset action was performed only after start then pause. This resolved the
earlier ambiguity: `[0, 0]` is pause, not a combined stop/reset operation.
The Control Center may now expose separate play/pause and reset controls; it
still needs direct hardware validation from this app before being called
working.

**Hardware validation completed (2026-07-12):** the native Control Center's
separate play, pause, and reset controls were directly tested on the physical
MiniToo and all behaved correctly. Stopwatch is now a completed feature. The
curated local capture is `../captures/stopwatch-reset-2026-07-12.cfa.curf`;
Android HCI-snoop logging was disabled again after collection.

## Initial control recovery race fixed (2026-07-12)

A real launch test exposed an ordering race in the first recovery design. The
app scheduled an automatic initial `WhiteNoise/Get` control probe, but opening
the menu immediately could run a normal menu-refresh probe first. That probe
had automatic recovery disabled, failed against the stale RFCOMM session, and
set the 15-second probe throttle; the scheduled initial probe then never got
the chance to perform its one Bluetooth reset. The user consequently had to
find the manual Debugging Tools recovery action.

`DivoomMenuBar` now tracks whether the initial end-to-end health check has
completed independently of the scheduled timer. Whichever probe actually runs
first during startup retains the existing one-shot recovery privilege. The
user directly confirmed a fresh app launch reached the full Ready diamond and
that brightness changed on the physical MiniToo without using Debugging Tools.

## Noise Meter capture (2026-07-12)

Official-app Start → short run → Stop was captured and decoded with the raw
btsnoop-capable `parse_divoom_spp.py` path. Noise Meter is tool `2`:
`0x71 [2]` reads it; `0x72 [2,1]` starts it; `0x72 [2,2]` stops it. The raw
capture is local-only at `../captures/noise-meter-2026-07-12.cfa.curf`.

**Hardware validation completed (2026-07-12):** the native Control Center's
Start and Stop controls were directly tested on the physical MiniToo. It
entered the device-side noise meter, reacted to nearby sound through its own
microphone, and stopped correctly. The final UI intentionally keeps only an
explanatory text note and a large start/stop control; it does not present a
Mac microphone indicator or a numeric level the capture does not support.

## Pixel Slot game launch capture (2026-07-12)

The official Game screen exposed Pixel Slot and instructed the user to start it
with the MiniToo's physical knob. The physical launch/exit interaction was
captured and decoded. The app-to-device launch packet is SPP command `0xA0`
with body `01 01` (`01 05 00 A0 01 01 A7 00 02` including the SPP wrapper).
This validates **Pixel Slot launch only**; it does not establish a generic game
ID scheme, game controls, or an app-driven exit command. The local-only raw
capture is `../captures/game-pixel-slot-2026-07-12.cfa.curf`.

## Alarm capture and physical firing test (2026-07-12)

The official Alarm UI exposes fixed device-resident slots (not arbitrary
add/delete records), each with time, repeat, enabled state, and notification
sound. Captured SPP list reads use command `0x42` with body `0x45`. The full
slot-write packet has not yet been isolated from this combined trace; do not
derive it from APK code alone.

A deliberately scheduled 7:50 PM slot was directly hardware-confirmed: the
MiniToo fired while in Atmosphere mode, played the selected bells sound, showed
the scheduled time plus an animated alarm-clock display, and required a
physical joystick press to dismiss. This proves alarm scheduling/execution is
device-local once configured, not a phone-side timer. The test slot was then
confirmed disabled. The local-only capture is
`../captures/alarm-fire-2026-07-12.cfa.curf`.

## Future integration: first-class AppleScript support (requested 2026-07-12)

The native app does **not** currently expose an AppleScript dictionary (`.sdef`)
or a documented `tell application` surface. The local daemon's developer
TCP/packet interface is not a stable automation contract and is not suitable
as the normal user workflow.

Future work should investigate a deliberately small AppleScript dictionary,
backed by the same app-side command paths as the menu and Control Center. It
should expose only capture-derived, user-facing operations and state queries,
for example: opening Control Center; reporting Bluetooth/control/battery
state; setting brightness; screen on/off; activating a confirmed custom face;
starting/stopping confirmed tools; and requesting a safe media-send workflow.
Commands need clear completion/error semantics and must not bypass the
project's opcode safety rules, Bluetooth discovery/cached-MAC policy, or
one-shot recovery safeguards. Prefer an explicit versioned scripting API over
fragile UI scripting; decide separately whether Shortcuts/App Intents should
share that command layer.

## Future display ideas: playful and Mac-contextual (requested 2026-07-13)

These are product ideas only. None has a MiniToo packet builder, UI, protocol
capture, or hardware confirmation yet. Treat every eventual display write as
new work through the existing **Send Media**/direct screen-buffer path: first
capture the official app's equivalent behavior when one exists, keep the
bricking-opcode guard intact, and require direct physical confirmation before
calling it working.

1. **Clarus the dogcow.** Add an opt-in menu-bar/Control Center action that
   sends a two-frame, tiny black-and-white dogcow animation: an idle frame and
   a speaking frame for the old-Mac-style “moooof.” The documentation
   recreation at [clarus-dogcow-concept.png](assets/clarus-dogcow-concept.png)
   now follows the classic Clarus side-profile glyph closely; it is a local
   reference asset, not an official Apple source file. Design the two frames
   for legibility on the MiniToo's 160×128
   display (and consider a deliberately pixelated 1-bit treatment), then
   validate animation timing and visibility on the physical device.
2. **Frontmost-app icon display.** Offer an opt-in mode that observes
   macOS frontmost-application changes and writes the newly active app's
   macOS icon to the MiniToo using the existing direct screen-buffer media
   pipeline. Use the app's real icon from the running application's bundle;
   do not build a hardcoded icon catalogue. Coalesce rapid app switches,
   downscale/crop deliberately to 160×128, and make the state/last update
   visible in the UI. This needs a privacy-conscious product decision and a
   clear off switch; merely receiving a macOS activation notification is not
   proof that the device display changed.
3. **Periodic screen sharing.** Offer an explicitly enabled, configurable
   screen-mirroring mode that captures a selected display or window roughly
   every 5–10 seconds, encodes it for the existing screen-buffer sender, and
   replaces rather than queues stale frames. It must use macOS's normal Screen
   Recording permission flow, make the capture target/interval/active status
   obvious, stop promptly on disable/app exit, and never silently capture.
   Start with still-image snapshots—not real-time video—and measure encode,
   Bluetooth-transfer, battery, and failure behavior before promising a
   cadence. A privacy warning is part of the feature: notifications,
   passwords, and other sensitive on-screen content can be mirrored to the
   device.

## Blind implementation batch: Countdown and Time Sync (2026-07-12; initial state, superseded below)

With no MiniToo connected, only already capture-derived behavior was enabled.
The native Control Center now exposes Countdown (tool 3) with a duration picker
and captured Start / Stop-and-Reset writes: `0x72 [3,1,minutes,seconds]` and
`0x72 [3,0,minutes,seconds]`. Physical pause/resume remains absent because its
protocol event has not been isolated. This is build-verified but **not yet
hardware-validated**.

Time Sync was moved into its own Control Center screen rather than being a
one-off Device Settings row. It sends the captured `Device/SetUTC` SPP JSON
body with both Unix seconds and a host-local `yyyy-MM-dd HH:mm:ss` string. The
screen defaults to the current Mac local time but allows a deliberate arbitrary
date/time, which enables a conclusive test: set five minutes ahead, confirm the
MiniToo display changes, then restore Current Mac Time. The device gives no
known clock read-back or application ACK, so UI text says "submitted", never
"synced" or "verified." A disabled `Automatic Sync (Coming Soon)` checkbox
documents the intended future automation without claiming any background action
exists. This too is build-verified but **not yet hardware-validated**.

Follow-up hardware testing found that the original native Time Sync submission
was a no-op. The raw time-sync capture differs from the first native frame in
two ways: its identity fields are `DeviceId:0`, `Token:576404986`, and
`UserId:404880831` rather than unrelated `Sys/SetConf` example constants, and
its command string is literal `Device/SetUTC`. Foundation's JSON serialization
emits the semantically valid but byte-different `Device\/SetUTC`, making the
native payload one byte longer than the official HCI frame. The identity fields
may be irrelevant, while the device may use a fragile literal command matcher;
neither hypothesis is proved. The next diagnostic build matches the official
JSON spelling/order exactly while retaining captured identity only temporarily,
then must be compared against a neutral identity submission before anything is
distributed. Do not treat account-derived fields as a generic protocol
requirement.

The MiniToo itself exposes an **Automatic synchronization time** setting. The
user observed this after the direct, byte-matched `Device/SetUTC` submission
still had no visible effect. That makes a device-side acceptance gate or a
connect-time-only synchronization path plausible, but it is not yet evidence
of either: the captured setting write and a controlled on/off test have not
been collected. The Control Center therefore only points the user to that
setting; it must not silently reconnect Bluetooth or claim that enabling it
will fix Time Sync.

That hypothesis was later disproved by direct testing: raw `0x18` clock-set
writes work even with the device-side setting off. The macOS app has no reason
to inspect, require, or mention that setting; it owns its own optional
automatic-sync schedule.

The controlled Android test (2026-07-13) set the tablet five minutes ahead
through its normal Settings UI, restarted the official app, and collected its
HCI log with `adb bugreport` (temporary `/private/tmp/divoom-time-sync-offset.curf`).
This resolved the mystery: `Device/SetUTC` is only preceding JSON bookkeeping,
not the visible clock setter. The official app immediately sends raw **opcode
`0x18`**, whose eight-byte body is `[year % 100, century, month, day, hour,
minute, second, weekday]`, with Sunday = 0. The deliberately offset official
session supplied the decisive instance `1a 14 07 0d 08 1d 06 01` for
2026-07-13 08:29:06 Monday; the earlier capture supplied
`1a 14 07 0c 11 11 36 00` for 2026-07-12 17:17:54 Sunday. The native Time Sync
implementation should therefore send only this token-free raw `0x18` frame,
not account-derived `Device/SetUTC` JSON. Direct hardware testing then
confirmed that both an arbitrary custom time and Current Mac Time visibly
changed the MiniToo clock. Manual Time Sync is hardware-confirmed.

Follow-up implementation made that checkbox functional and persisted, default
off. The `ClockSyncModel` now lives with the menu-bar app rather than the
Control Center window, so it survives closing the window. When enabled it
sends the already-confirmed raw `0x18` write every 10 minutes and after
macOS's `NSSystemClockDidChange` notification. This is a passive operating
system event, not MiniToo polling; it does not reconnect Bluetooth, and it
skips a tick while another clock write is in flight. Enabling it schedules an
immediate one-second-delayed current-time write so the user can verify the
setting without waiting ten minutes. This background behavior is
hardware-confirmed: setting a deliberate custom offset and enabling the
checkbox returned the MiniToo to current Mac time immediately.

Countdown was directly hardware-confirmed working; its UI was then revised
from two menus to a single numeric `mm:ss` field, with a bounded 00:01–99:59
range and adjacent up/down stepper arrows. Live input filtering prevents text,
extra digits, and impossible seconds; that revised UI itself still needs a
quick usability check.

Scoreboard remains deliberately disabled. The user-facing score increment and
reset behavior was observed in the official app, but no recoverable captured
write body remains in local artifacts; do not construct a guessed tool-1
packet from APK code or memory.

The Games screen now exposes **Pixel Slot only**, using the previously decoded
official-app packet `0xA0 [1,1]`. Its UI explicitly tells the user to press the
MiniToo's physical knob after launch; no other game IDs, in-game controls, or
software return command were added. Launching Pixel Slot from the native UI was
hardware-confirmed on 2026-07-12. Further games and software exit behavior
remain capture work.
