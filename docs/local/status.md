# Status (fork-local)

Current state of each feature on `personal` — includes work still sitting
in unmerged upstream PRs, so this does NOT represent alvinunreal/main's
actual state. Edit in place when status changes; this is a table, not a
log.

| Feature | Status |
|---|---|
| Brightness (`0x74`) | Done, hardware-tested. |
| Screen on/off | Done, hardware-tested. |
| Custom faces 1-3 (`ClockId` 984/986/988) | Selection works, hardware-tested. All 3 slots are currently **empty** — nothing has ever been uploaded into them. How to populate a slot is unknown (see `dev-notes.md`). Select command ported to native Swift (`DivoomClockFrame.swift`) 2026-07-11, no Python involved; re-confirmed working on hardware after the port. |
| White Noise | Done. Per-channel sliders + on/off toggle, real device-state readback, quiet auto-refresh with a user toggle. |
| Photo Album | Done, stills only. Multi-frame/video was implemented and hardware-tested but reverted — the official Divoom app itself doesn't support adding video to this feature on the current app version either. Ported to native Swift (`DivoomAlbumEncode.swift`, CoreGraphics/ImageIO instead of Pillow) 2026-07-11, no Python involved; hardware-confirmed working after the port. |
| Atmosphere | Done. 21 backgrounds + 6 text effects, real on-device names, state readback, quiet auto-refresh. Lyric text is **confirmed via Android HCI capture** to be standard AVRCP: MiniToo is the Controller and requests `GetElementAttributes` after `RegisterNotification(TRACK_CHANGED)` — not SPP_JSON, no Divoom opcode risk. **Live lyrics from a Mac while its audio plays through MiniToo are shelved (2026-07-10):** public Now Playing tests were physically negative; raw AVCTP PSM `0x17` works only after audio disconnects; an app cannot change bluetoothd's existing AVRCP record; and daemon patching is not shippable. A Linux bridge/Android companion is outside the accepted product scope, so no Dell SDP experiment is planned. Revisit only for a supported macOS AVRCP metadata-target API or changed MiniToo/macOS behavior. Details: `dev-notes.md` and PROTOCOL.md. |
| Full-screen send (160×128) | **Working again, hardware-confirmed 2026-07-10** — user directly tested still image and MP4/video, both full-screen and default 128×128, all four combinations sent and displayed correctly on the physical device with no crash (all had previously failed at full-screen). Fix applied: `ControlCenterModel.buildPreview()`/`send()` named the built packets file from the media filename alone with no per-build uniqueness; concurrent `buildPreview()` calls (e.g. toggling "Full Screen" while a prior build is still in flight) could race on writing the same `*-packets-lenpref.bin` path, and `send()` could submit whichever file a stale completion last pointed `packetsPath` at. Fixed by giving each `buildPreview()` call its own generation-numbered output subdirectory plus a generation guard on stale completions. **Caveat, stated plainly:** the user's own recalled repro steps (one file, one/two clicks of Send, no toggling) don't obviously exercise that race — `send()` alone never calls `buildPreview()` again — so this fix is confirmed to have *resolved* the crash across a real multi-trial hardware test, but the race condition may not be the full/original root cause; treat as fixed-in-practice, not fully explained. Payload bytes were separately verified byte-for-byte identical between the original hardware-confirmed commit (`5457c83`) and current code for a 160×128 still image, ruling out any encoding-side regression. If this regresses again, the next-best suspect is transfer-duration sensitivity in the daemon's RFCOMM write path (`DivoomDaemon.swift`'s 2s per-chunk stale-write timeout) — full-screen is ~25% more data/packets than default, so it's a longer transfer with more chances to hit that timeout or an ordinary Bluetooth hiccup mid-stream. **Ported to native Swift 2026-07-11** (`DivoomMediaEncode.swift`/`DivoomProcess.swift`, replacing Pillow/zstandard/Python's ffmpeg-subprocess glue with CoreGraphics/CoreImage/vendored zstd/Swift `Process` — ffmpeg itself is still bundled and does all scale/crop/fps/eq decoding, just invoked directly by Swift now). Hardware-confirmed working for still image and MP4/video, both full-screen and default, across multiple trials. One single non-reproducible crash occurred on full-screen MP4 during that testing (did not recur after a reboot across several retries) — see `dev-notes.md`'s 2026-07-11 follow-up note; not chased further given it fits the already-documented RFCOMM-timeout suspect better than a new code bug, and the daemon's send path is unchanged by this port. |
| Device MAC address | Done. No longer hardcoded anywhere — discovered via in-app Bluetooth scan, cached in `UserDefaults`. |
| Device rename (`0x75`) | **Shelved**, code moved to `shelved/device-rename` branch (off `personal`). Protocol verified byte-for-byte against a real capture, but on-device persistence of a new name is unreliably flaky for reasons still unknown. Full story in `dev-notes.md`'s "Known gotchas". No PR opened. |
| Alarms (`0x43`/`0x42`) | APK-decoded only, never hardware/capture-verified. |
| Games (`0xa0`/`0x17`/`0x21`/`0x88`) | Same as Alarms. |
| Device Settings (`Sys/SetConf`) | **Hardware-tested (2026-07-07)** end-to-end from this app's own UI: temperature unit, date format, clock format (including the `Time24Flag` 0/1↔12h/24h mapping itself), Bluetooth auto-reconnect, remember-power-on-volume, auto power off all confirmed working against a real MiniToo. Notification sound (level slider) confirmed reachable, not independently confirmed audible. No device-side state readback exists for this command (confirmed by direct testing, not just capture absence) — screen caches last-sent values in `UserDefaults` instead, with a `(?)` tooltip explaining that's not a live read. "Shake Shake" and "Tap and Play" confirmed **not** BT-transmitted — Android-local only, not implemented. Known MiniToo firmware quirk: its own on-screen settings menu can show stale text after a change until backed out and re-entered (documented in README.md). See PROTOCOL.md's "Device Settings" section. |
| App icon | Done (2026-07-07). `assets/AppIcon.icns` wired into the bundle via `CFBundleIconFile`, confirmed rendering correctly in Finder (icon-view + Get Info). First pass (thin coloring-book line art) was unreadable at 16-32pt; measured actual rendered sizes side-by-side and found two fixes needed: bold, high-contrast linework (3x stroke width, simplified fine detail) and a tight crop (content filling ~90% of the 1024 canvas, not ~74%) — a solid dark glyph on the screen is what actually survives downscaling, thin outline detail doesn't. Current source (`assets/AppIcon-source.png`) is the user's Gemini-refined "Candidate5" render, trimmed to content bbox at its native ~657×750 resolution (an earlier pass mistakenly used a crop pulled from a Downloads contact-sheet image instead of the actual selected candidate — caught and fixed same session). Regen steps in README.md. |

## Next feature batch (approved 2026-07-10)

These are the next items to investigate and implement in the menu-bar UI, in
this order. They are APK-decoded only at this point: capture the official
app's traffic and obtain direct user hardware confirmation before marking any
one working.

1. **Noise Meter** — Done, capture-derived and hardware-tested 2026-07-12.
   Uses the MiniToo's onboard microphone (never the Mac's). The native Control
   Center uses tool-2 `0x72` writes `[2,1]` Start and `[2,2]` Stop, directly
   observed and acknowledged in Android HCI traffic; the user directly
   confirmed both actions work on the physical MiniToo. No numeric sound-level
   readback is exposed because the capture does not establish one.
2. **Scoreboard** — Swift/Control Center icon and disabled UX prototype added
   2026-07-11 (two three-digit scores, reset, on/off). Still APK-decoded only;
   no device command is enabled pending capture and hardware validation.
3. **Countdown Timer** — Swift/Control Center icon and disabled UX prototype
   added 2026-07-11 (duration, start, reset). Still APK-decoded only; no device
   command is enabled pending capture and hardware validation.
4. **Stopwatch** — Done, capture-derived and hardware-tested 2026-07-12.
   The native Control Center uses tool-0 `0x72` writes `[0,1]` Start,
   `[0,0]` Pause, and `[0,2]` Reset, each directly observed and acknowledged
   in Android HCI traffic. The user directly confirmed all three controls
   work on the physical MiniToo.
5. **Alarms** — Swift/Control Center icon and disabled UX prototype added
   2026-07-11 (alarm list and add action). Still APK-decoded only; no device
   command is enabled pending capture and hardware validation.
6. **Games** — Swift/Control Center icon and disabled UX prototype added
   2026-07-11 (built-in game launcher). Still APK-decoded only; no device
   command is enabled pending capture and hardware validation.

### Next execution step: capture batch, then implementation

Do **not** enable any of the six prototype panes from APK/static research
alone. The next work starts with Android Bluetooth HCI-snoop captures of the
official app, then ports only the observed traffic into the existing Control
Center shells, followed by direct user hardware confirmation.

1. **Implement and hardware-test the remaining captured tool views:**
   Scoreboard, then Countdown. Stopwatch and Noise Meter are complete. Keep
   Countdown's physical pause unsupported until a cleaner capture isolates a
   distinct command/event; its official-app-equivalent Start and Stop/Reset
   surface is the current target. Exit tool views with the MiniToo's physical
   button; there is no confirmed software return-to-clock command.
2. **Alarm capture/test session:** capture list/read, add/edit, enable/disable,
   and delete flows. Only after decoding them, perform a deliberate user-owned
   near-future alarm test and directly confirm it fired as expected.
3. **Games capture session:** capture launching each available official-app
   game and any exit/return behavior. Do not infer game IDs or send the
   APK-decoded opcodes until this is observed.
4. **Implement and verify in order:** Scoreboard, Countdown, Alarms, Games.
   Keep each feature disabled until its own capture-derived packet builder and
   user hardware test are complete.

Sleep-control commands remain a separate research question, not part of this
batch. The project's existing warning is based on external reverse-engineering
and generic Divoom mapping, not a bricking event personally observed by this
project’s user; do not weaken the send guard or transmit any of those opcodes
without an explicit capture-first test plan and a hardware power-cycle
recovery path.

## Time synchronization (to-do)

The official Android app's real HCI-snoop traffic (not merely APK tracing)
shows a normal `SPP_JSON` (`0x01`) command, `Device/SetUTC`, sent as part of
its post-connection startup burst. Its body contains `Utc` as the host's Unix
time in seconds and `Time` as the host's local `yyyy-MM-dd HH:mm:ss` clock
string; `DeviceId`, `Token`, and `UserId` use the normal JSON identity fields.
The APK code corroborates this construction. The capture is
`../captures/device-settings.cfa.curf`, record 487 (and another send at record
8116); see `apk-analysis/jadx-out/sources/com/divoom/Divoom/bluetooth/CmdManager.java`.

Implement a visible **Sync Clock Now** action and last-submitted timestamp in
the real Device Settings UI, then automatically submit the same command after
the RFCOMM control connection becomes ready, after Mac wake or a system
clock/time-zone change, and at a conservative periodic interval while the
daemon is active. Coalesce duplicate triggers. The MiniToo provides no known
time readback or ACK for this command, so “last synced” must describe the last
submission, not proven device state. Before calling it working, deliberately
test it on hardware and obtain the user's direct visual confirmation that the
MiniToo clock changes to the Mac's current local time.

## Planned connectivity-status/menu redesign (capture work may proceed first)

The MiniToo has distinct Bluetooth uses: the app protocol is an RFCOMM/SPP
control channel, while playback uses an A2DP audio profile. The user's
observed two-computer contention is consistent with those profile/session
layers being independently usable or unavailable. The current menu incorrectly
calls `IOBluetoothDevice.isConnected()` an "Audio profile" state; it is only a
generic Bluetooth link indication and cannot prove that either local A2DP or
end-to-end RFCOMM control works.

Before changing the menu, define one asynchronous `ConnectivitySnapshot` from
these separate signals:

| Signal | Meaning / source | Do not infer |
|---|---|---|
| Setup/pairing | Saved address plus a matching macOS paired-device record | That the device is in range or has accepted a connection |
| Bluetooth controller | Public IOBluetooth power state | Any MiniToo connection or profile state |
| Generic MiniToo link | `IOBluetoothDevice.isConnected()` | A2DP audio, RFCOMM health, or which host owns a profile |
| Local audio route | Future measured CoreAudio route check: unavailable / available / selected / unknown | Any other computer's audio connection or control ownership |
| Daemon lifecycle | stopped / starting / stopping / process present | That the daemon can talk to the MiniToo |
| Control health | A rate-limited, known-safe `WhiteNoise/Get` request through the local daemon that receives a parseable MiniToo reply | That audio is connected, or why a negative probe failed |

`WhiteNoise/Get` is already capture-derived and hardware-confirmed as a read
of device state; it is the candidate end-to-end health probe, not a brightness
write whose visual effect requires a human to observe. A failed probe must be
reported neutrally as **Control unavailable** (with possible causes such as
another device/session, range, or stale RFCOMM), never falsely as "audio is
connected." This Mac cannot enumerate another host's Bluetooth profile use.

### Planned health indicator

Use both a glanceable overall indicator and explicit component rows. A single
red/yellow/green light alone is insufficient because the useful partial states
are exactly the point of this redesign.

- **Menu-bar glyph:** retain a monochrome state shape (macOS menu-bar template
  icons should not be relied on for color): ready / partial / unavailable /
  checking. Its accessibility label states the same overall state.
- **Menu header health card:** a small custom AppKit menu view with colored
  dots and text, rather than treating disabled menu items as status controls:
  `Bluetooth link`, `Audio on this Mac`, and `Control`. The local-audio row
  distinguishes *available* from *selected*; available-but-not-selected is a
  good outcome for a user who merely wants playback to remain possible.
- **Overall green — Ready:** configured and paired, Bluetooth link up, local
  audio route is measured available (selection is not required), and a recent
  control probe has received a valid reply.
- **Overall yellow — Partial / needs attention:** any useful but incomplete
  combination, such as audio available but control unavailable, control live
  while audio is unavailable/unknown, a daemon transition, or a stale probe.
  The component rows state which condition is missing.
- **Overall red — Unavailable:** Bluetooth off, no configured/paired device,
  or neither local audio availability nor live control can be established.
- **Overall gray — Checking:** no completed snapshot yet; never present stale
  "connected" data as current while probing.

Refresh the cheap local signals on menu open and after each lifecycle action.
Probe control only after daemon startup/retry and when a cached successful
probe is older than a modest TTL while the menu is open; do not turn the menu
into a continuous device poller. The first implementation must validate that
CoreAudio can reliably correlate the configured MiniToo with a local output
route; until then show Audio as **Unknown**, not guessed. On launch, preserve
any existing healthy daemon and do not call the generic `closeConnection()`
"disconnect first" path merely to establish status. The sole exception is one
automatic reset after the initial read-only control probe proves the inherited
RFCOMM channel unusable; later/manual recovery remains a named,
user-confirmed action.

**Connection-status implementation (2026-07-12):** Control Center's
unfinished tiles are now badged/disabled. The control service resumes/starts
automatically on launch without deliberately disconnecting Bluetooth. The menu
distinguishes a generic Bluetooth link, conservative local CoreAudio route
state (exact saved-name match only; otherwise Unknown), and an end-to-end
`WhiteNoise/Get` control probe. The status-bar glyph is monochrome: `×` only
when Bluetooth is unavailable, `○` when Bluetooth is on but there is no
MiniToo connection, `◐` only for an actual incomplete MiniToo connection, and
`◆` when all measured components are ready. Bluetooth-off intentionally
collapses to a simple instruction rather than a diagnostic matrix. The generic
`closeConnection()` recovery is used automatically only by the one-shot failed
initial-probe path; it otherwise remains a confirmation-gated Debugging Tools
action because it can interrupt audio and is not a targeted audio-profile
operation. Debugging Tools intentionally remains stable rather than
context-pruned: its actions are the escape hatch if status inference is wrong
or incomplete. Hardware validation is still required before calling
CoreAudio's name correlation reliable or finalizing the display/action policy.
When Bluetooth is on but MiniToo itself is not linked, the menu intentionally
shows only `MiniToo: Not connected` and one plain control-service waiting/not-
running line; it hides redundant transport/audio/control rows and any stale
battery value. Battery is displayed as a standard left-aligned percentage
row; do not use a custom menu view to force an icon position. A saved MiniToo
audio name absent from CoreAudio is shown as **Unavailable** (and makes
overall state `Partial — audio unavailable`); only a missing saved name or
ambiguous CoreAudio match is **Unknown**.

**CoreAudio follow-up (2026-07-12):** Hardware/UI validation
showed macOS correctly listed and selected `Divoom MiniToo-Audio` while the
app still showed Unknown. The first CoreAudio implementation read
`kAudioObjectPropertyName` with `takeUnretainedValue()`, but Apple's SDK
documents the returned `CFString` as caller-owned. It now uses the correct
`Unmanaged<CFString>?` storage and `takeRetainedValue()` ownership transfer.
The diagnostic then showed two live CoreAudio objects with that same exact
Bluetooth name—one was the default output—so the initial “exactly one match”
rule also incorrectly returned Unknown. The final rule treats same-named live
objects as one route: default output means Selected; otherwise any live match
means Available. The user's physical test confirmed macOS audio playback on
MiniToo while selected; re-test the app display after rebuilding.

**Name identity rule (2026-07-12):** The discovered Bluetooth MAC
is the stable identity used to open RFCOMM and inspect the generic link; it is
never replaced by a display name. The display name is only the CoreAudio
correlation hint. On status refresh the app reads the current IOBluetooth name
for that saved MAC and updates its cached scan name when it has changed, so a
normal Bluetooth rename tracks automatically rather than requiring a rescan.
The menu-bar glyphs use an open diamond for no MiniToo connection, a
bottom-half-filled diamond for partial connection, and a filled diamond for
Ready; Bluetooth-off remains an explicit × state.

**Ready-state density (2026-07-12):** In Ready, the filled
menu-bar diamond already supplies the aggregate result. Do not also show
`MiniToo: Ready` or `Daemon: Running`: the former repeats the aggregate and
the latter is implied by a successful `Control: Live` reply. Keep the three
independent user-facing rows—Bluetooth link, local audio route, and control
health—plus battery. Labels are user-facing: `Bluetooth`, `Audio on this
Mac`, and `Device control: Working`; they avoid making the daemon an ordinary
user concern. Battery is a standard left-aligned `NSMenuItem` whose icon is an
inline title attachment after the percentage; do not use a custom menu view,
leading menu image, or hand-tuned position. Do not put `Last:` in the main
menu at all: even a harmless brightness adjustment should not move the normal
controls. Routine status is omitted; non-routine action results/errors appear
only as `Latest status:` inside **Debugging Tools**.

**Initial control status (2026-07-12):** The first implementation
only ran the existing read-only `WhiteNoise/Get` health probe when the user
opened the menu, so the status bar could remain Partial until clicked even
though the daemon and audio route were already ready. Schedule exactly one
probe after daemon launch or reuse so the status glyph updates independently.
Keep the menu-open TTL for later refreshes; this is not a continuous heartbeat
or a speculative passive signal.

**Control lifecycle correction (2026-07-12):** A follow-up
interactive test exposed two real state-machine mistakes. First, starting or
restarting set the visible state to `Checking…`, while the probe scheduler
mistook that visible state for an in-flight probe and therefore refused to
probe; a working service could remain stuck in `Checking…`. Probe-in-flight is
now tracked separately from the visible state. Second, stopping did not
invalidate a reply already in flight or publish `Stopped` until after process
teardown, so the full diamond could remain visible briefly. Stop/start now
invalidate old callbacks and immediately publish the correct partial/stopped
state. The top-level menu has exactly one contextual recovery action:
`Start Control Service (currently stopped)` when absent, or `Retry Control
Service` only when a running service is unhealthy. Stopping and restarting are
debugging/recovery operations and therefore live only in **Debugging Tools**;
there is no top-level Stop action and no confusing Retry+Stop pair.

**Stale RFCOMM launch recovery (2026-07-12):** A real launch
regression showed why the original startup path had a disconnect step. The
menu app found an existing `divoom-daemon` process and reused it, but the
daemon's RFCOMM channel was stale (`0x-1ffffd44`): macOS audio and the generic
Bluetooth link were healthy while `WhiteNoise/Get` could not obtain a valid
reply. The control probe correctly reported **Unavailable**, but process
existence was incorrectly treated as a sufficient startup condition. Launch
now remains non-disruptive when its initial probe succeeds. If—and only if—the
first probe fails, it stops that daemon, closes the generic MiniToo Bluetooth
connection once, and starts a fresh daemon; a second failure is reported and
never loops or triggers further automatic disconnects. Menu-open probes do
not invoke this recovery. The manual Debugging Tools recovery remains for a
later failure in the same launch.

**Published software checkpoint (2026-07-12):** Commit `cb31991` implements
the menu lifecycle/state corrections, one-shot stale-RFCOMM launch recovery,
and Debugging-Tools-only `Latest status` diagnostics. Local Swift tests and
arm64 packaging passed; GitHub Actions run `29201480002` passed unit tests,
both architecture slices, universal assembly, and publication. The user has
physically confirmed the manual Bluetooth-reset recovery path restores device
control. The new *automatic* failed-probe recovery still needs a deliberate
hardware observation before it can be called verified.

### Intended menu states

1. **No configured/paired MiniToo:** show `Set Up MiniToo…`; no daemon or
   connection actions.
2. **Bluetooth off:** show a Bluetooth-off status and `Open Bluetooth
   Settings…`; no start/disconnect/reconnect actions.
3. **Configured but missing/unpaired:** show `Set Up MiniToo…` / rescan;
   no daemon actions.
4. **Control daemon stopped:** normal app launch starts the control service
   automatically without disconnecting Bluetooth. If it is subsequently
   stopped, replace daemon-status text with the useful top-level action
   `Start Control Service (currently stopped)`. Debugging Tools always exposes
   the explicit,
   confirmation-gated `Disconnect MiniToo Bluetooth + Retry Control Service…`
   recovery action; it must say it can interrupt this Mac's playback and
   generic Bluetooth connection.
5. **Daemon starting/stopping:** show status only, with no competing action.
6. **Control healthy:** show no normal lifecycle action; put Stop and Restart
   in Debugging Tools rather than presenting them as ordinary use.
7. **Daemon unhealthy/control unavailable:** show only `Retry Control Service`
   plus troubleshooting/log access. Explain that another device may be using
   MiniToo, but do not claim that as fact.

The standalone `Disconnect Divoom Audio` / `Reconnect Divoom Audio` items are
to be removed or replaced after local audio-route detection is validated:
`IOBluetoothDevice.closeConnection()`/`openConnection()` operate on the
generic link and are not truthful audio-profile controls. The top status label
will become **MiniToo Bluetooth link**; local audio and control health will be
shown separately only when measured. Implement with a pure state reducer,
asynchronous refresh (never mutate connections while merely opening the menu),
serialized start/stop/retry actions with internal precondition rechecks, unit
tests for every state/action combination, and manual tests including a second
computer contending for audio/control.

## Long-term release hardening

- **Deferred independent-fork identity transition.** Before broader public
  distribution, decide whether to rename the app/project and make the active
  integrated branch this fork's `main` (replacing `personal`). This requires
  legal distribution-rights review, preserved upstream attribution, a
  bundle-ID/UserDefaults migration, workflow retargeting, and no claim of
  upstream takeover. See `docs/local/branch-workflow.md`; no rename or branch
  promotion is approved yet.

- **Remove the Python runtime dependency from the shipped app — done
  2026-07-11.** Migrated the media/custom-face/photo-album pipeline to
  native Swift/macOS APIs: image resize/crop via CoreGraphics
  (`DivoomImageResize.swift`), JPEG encode via ImageIO
  (`DivoomAlbumEncode.swift`), zstd compression via a vendored zstd 1.5.7
  compiled directly into the app (`DivoomZstd.swift`,
  `tools/vendor/zstd-1.5.7/`), and packet construction/chunking
  (`DivoomMediaEncode.swift`, `DivoomChunkedUpload.swift`,
  `DivoomClockFrame.swift`). FFmpeg is still bundled and still does all
  video/GIF scale/crop/fps/eq decoding exactly as before — only the
  process invoking it changed, from Python's `subprocess.run` to Swift's
  `Process` (`DivoomProcess.swift`). PyInstaller/`.venv` freezing and
  bundling is entirely removed from `build-divoom-app.sh` and the release
  workflow. Hardware-confirmed working (custom face, Photo Album, Send
  Media stills and video/GIF, both full-screen and default) before this
  deletion landed. The original `tools/divoom_*.py` scripts and
  `requirements-app.txt`/`.venv` remain in the repo as standalone
  dev-CLI/protocol-debugging tools, per an explicit decision — they're
  no longer referenced by the app build at all. The vendored zstd test coverage
  now includes test-only portable decompression and real compression
  round-trips; production paths remain compression-only. Full story, including
  the zstd C-interop mechanics proof, in `dev-notes.md`.
- **Native Bluetooth migration.** `blueutil` has been removed from app setup
  and connection management in favor of public `IOBluetooth`. Scan/pairing
  were physically confirmed; nearby-unpaired discovery and native
  disconnect → RFCOMM-open / reconnect audio remain explicit release checks.

- **Self-update / Sparkle — done for the ad-hoc-signing phase (2026-07-11).** The app now has a
  pinned SwiftPM/Sparkle update path, embedded repository/branch/channel build
  provenance, first-launch update consent, Preferences/About visibility, and
  a branch-locked signed-feed workflow design. The pre-notarization relaunch
  flow gives the user an explicit, default-checked choice to remove quarantine
  from the verified staged update; it never does so silently. Local universal
  packaging and appcast-generation checks pass. Hosted CI publication passed
  end-to-end in run `29154079898`: both architecture slices, universal DMG,
  signed one-item Personal appcast, immutable update ZIP, and release publish
  all succeeded. The user then confirmed first-launch consent, branch/build
  provenance UI, and a real in-app update: Gatekeeper clearance is required
  only for the initial DMG install, not subsequent verified updates. The CI
  design retains only the newest three immutable update releases. Developer ID
  signing/notarization remains the future hardening step. See
  `docs/local/update-strategy.md`; no Bluetooth/device behavior changed or was
  tested here.

- **Supply-chain security hardening — planned and deferred (2026-07-11).** An
  authenticated review found no current compromise, but confirmed that neither
  `personal` nor `main` is protected, the Sparkle signing key is a
  repository-level Actions secret, and every `personal` push can currently
  reach a workflow with release authority. The first future hardening unit is
  to separate unprivileged automatic CI from approval-gated release signing,
  then pin Actions and verify external FFmpeg source. Full findings,
  dependency exposure, tradeoffs, and acceptance checks:
  `docs/local/security-supply-chain-plan.md`.

## Upstream docs housekeeping
PR #11's description was updated with a root-cause sentence (no branch diff
change). PR #16 is a new standalone upstream docs PR carrying the
custom-face dead-ends and Bluetooth troubleshooting notes. Device-rename
docs stay local-only until that feature gets its own PR.

## Upstream PR: Device Settings
[PR #17](https://github.com/alvinunreal/divoom-minitoo-osx/pull/17) opened
2026-07-07, `feat/device-settings` branch, cut from `personal`'s tip (same
pattern as #15) — depends on #2/#4/#6/#7/#10/#11/#12/#13/#14/#15 all
merging first per its own "Depends on" section. `docs/local/` was
stripped out of that branch before opening (fork-local content, never
upstreamed).

## Distribution test notes (2026-07-10)

- Native scan and pairing were physically confirmed after replacing `blueutil`.
  The initial scan implementation incorrectly displayed saved pairing records
  as discovery results and did not handle controller-off state; corrected code
  now distinguishes nearby inquiry results from saved records. Re-test nearby
  unpaired discovery after rebuilding.
- Brightness and Device Settings were physically observed working.
- White Noise transport appeared to work, but its screen-mode behavior is
  inconsistent: turning it on left the previous screen intact, while turning
  it off switched to Atmosphere. Treat a user-facing “change screen mode”
  option as a future UX/protocol investigation; do not infer correctness from
  the transport result alone.
- Media send and Photo Album failed before transport because the app used raw
  Python scripts instead of the frozen helper (`ModuleNotFoundError: serial`).
  Packaging layout corrected; re-test still, GIF, MP4/video, and album upload.
- Time synchronization behavior/protocol remains unresearched; add it to a
  future protocol investigation rather than guessing a command.
- Full-screen media sends are quarantined: a 160x128 JPEG got no final ACK
  and visibly crashed the MiniToo, while the same image works at 128x128.
  An earlier version of this app's full-screen path was physically working.
  The UI control is disabled pending a regression diff of the old known-good
  app packet stream versus the current stream for the same input—not a new
  Android capture. Compare payload headers, zstd bytes, length-prefixed packet
  files, chunk boundaries/delays, and daemon submission. **Resolved
  2026-07-10 — see the Full-screen send row in the feature table above and
  `docs/local/dev-notes.md` for the fix; full-screen is re-enabled and
  hardware-confirmed.** The current video
  preview intentionally displays only its first encoded frame; animated
  preview playback is a separate future UI feature.
- Follow-up hardware check: normal Send Media (including MP4/video) works
  after the frozen-helper/FFmpeg packaging fixes. Photo Album successfully
  accepts the same JPEG at its normal 160x128 full-panel size. This is not a
  contradiction: Album uses its distinct persistent JPEG/blob protocol, not
  Send Media's live `0x8b` zstd chunked-stream protocol. Several additional
  menu functions appeared to work in exploratory testing; record any specific
  failures before marking individual behaviors hardware-verified.
- First GitHub Actions run (`29100401008`) failed before release assembly:
  Apple Silicon exited during no-identity signing lookup (not Python/venv),
  and Intel FFmpeg configure required missing NASM. Both workflow/build-script
  issues are corrected; the next push must validate the hosted build.
- Final pre-release local check: normal Send Media and nearby-unpaired
  discovery pass; the White Noise display-mode behavior is accepted for the
  alpha. The next gate is the first GitHub Actions build and its generated
  universal artifact; no commit/push had occurred at the time of this note.
- Hosted release pipeline is now proven end-to-end. The initial two failures
  (`29100401008`, signing/NASM; `29112757315`, same-path `mv`) are corrected;
  `29113738061` first assembled/published successfully. The current styled-DMG
  run (`29118886535`) also succeeded. The rolling `personal-latest` prerelease
  publishes a universal DMG, its SHA-256 checksum, and the separate matching
  FFmpeg 8.1.2 source archive—never the source archive inside the DMG.
- **CI cache optimization is verified:** `29115469899` warmed the per-arch
  FFmpeg and pip caches; `29116481715` and later runs restored FFmpeg instead
  of recompiling it. The cache key includes architecture, source version and
  build-script/configuration hash; `ffmpeg-cache-v1` is the deliberate
  invalidation switch. Do not cache `.venv`, FFmpeg intermediates, Homebrew,
  or release artifacts.
- **DMG presentation:** the release DMG uses a Finder background with two
  reserved panels and deterministic icon positions for `Divoom MiniToo.app` and
  `INSTALLING.md`. The selected background is a lightly colorized pixel-art
  night scene; it is a presentation asset only and does not include FFmpeg
  source (which remains a separate release attachment). The published DMG's
  Finder metadata was inspected: it assigns the background and places the app
  at `(195,258)` and guide at `(597,258)` inside the matching panels. A fresh
  human Finder visual check remains requested.
- This session made no Bluetooth/device changes or tests. Existing device
  connection state was not touched; an independent real-Mac install/launch,
  scan/pair, and basic-send confirmation remains required before broad public
  distribution, along with the separate upstream distribution-rights decision.
- **DMG background-visibility bug found and fixed:** the requested Finder
  visual check surfaced a real defect — `dmgbuild` names the compiled HiDPI
  background `.background.tiff` and relied only on the leading dot to hide
  it, which fails for any user with Finder's "show hidden files" on. It
  showed up as a stray "TIFF" icon auto-placed at the window's top-left
  (no assigned position), disconnected from the artwork. Fixed in
  `tools/dmgbuild-settings.py` by adding it to the `hide` setting (forces
  the actual Finder-invisible attribute via `SetFile -a V`, confirmed
  locally with `GetFileInfo`/`ls -lO` showing the flag set) plus an
  off-canvas `icon_locations` fallback. Confirmed by the user's own Finder
  screenshot: the stray icon is gone.
- **DMG window-size bug found and fixed:** the same visual check showed a
  vertical scrollbar cutting off the bottom of the background artwork.
  `window_rect`'s height sets the whole Finder window frame, not the
  content viewport, and it was set to exactly 496 (the background's
  height) with no allowance for the title bar. Measured the exact
  overhead directly via `NSWindow.frameRect(forContentRect:styleMask:)`
  for this window's style (titled/closable/miniaturizable/resizable, no
  toolbar): 32pt. Fixed by setting `window_rect` height to `496 + 32`;
  verified locally by building a test DMG and reading the resulting
  `.DS_Store`'s `WindowBounds` directly (`{{100, 100}, {793, 528}}`).
  Confirmed by the user's own Finder screenshot: the height 32pt fix
  alone wasn't enough — a large scrollbar remained. Root-caused with the
  user's Finder access granted this session: their Mac has "show hidden
  files" on (`defaults read com.apple.finder AppleShowAllFiles` → `1`),
  which reveals dotfiles *and* Finder-invisible-flagged files alike —
  there is no OS-level hiding mechanism dmgbuild has that survives that
  preference, and a shipped DMG has no business trying to override a
  user's own Finder setting. The actual scrollbar culprit was the
  `.background.tiff` off-canvas `icon_locations` position added for the
  earlier fix: any `Iloc` entry, even for a hidden file, expands the icon
  view's scrollable canvas to include it. Fixed by moving that position
  inside the visible canvas, at a corner (`(30, 30)`) — for the vast
  majority of users (hidden files actually hidden) it's irrelevant; for
  users with the "show hidden files" preference on, it now shows as a
  small, contained icon in a corner instead of forcing a scroll. Verified
  directly via a locally built test DMG opened in Finder (with the user
  present to grant computer-use access): no scrollbar, background fully
  visible, `.background.tiff` visible only as a small top-left icon.
- **DMG window-size bug, round 2 — residual ~1pt crop plus a real Status
  Bar/Path Bar caveat:** the user methodically compared four states of
  the same mounted DMG (both bars on; path bar hidden; both hidden;
  manually resized) and found that even with both bars off, the window
  still cropped the artwork's border by a hair — manually resizing to
  793x529 (vs. the shipped 793x528) fixed it completely. Some fixed
  inset this macOS version's icon view reserves beyond pure window
  chrome, not accounted for by the earlier NSWindow-based title-bar
  math. Fixed by adding a small margin: `window_rect` height is now
  `496 + 32 + 4 = 532`; verified by reading the built DMG's `.DS_Store`
  directly (`WindowBounds` → `{{100, 100}, {793, 532}}`) and visually
  confirming the corner border renders complete. Separately confirmed
  (both by the user's own toggling and an independent test): Finder's
  Status Bar/Path Bar are real, user-controlled via the View menu, and
  when on they visibly consume space from this same fixed-size content
  area rather than growing the window to compensate — dmgbuild's
  `show_status_bar`/`show_pathbar` settings have no effect on this macOS
  version (confirmed via an A/B test: forcing both `True` rendered
  identically to `False`), and there is no way to override the user's
  own global Finder preference from inside a shipped DMG. **Refined by
  the user's own direct testing: only Path Bar causes the crop — Status
  Bar alone does not.** Both are off by default on a fresh macOS account
  (confirmed via web search, not assumed), so decided against padding
  for the on-case: most users won't hit it, and the fix would cost
  everyone else a visible empty margin below the artwork. Known,
  accepted limitation for users who've explicitly turned Path Bar on.
