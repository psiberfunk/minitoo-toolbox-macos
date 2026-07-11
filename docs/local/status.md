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

1. **Noise Meter** — first item. User reports the MiniToo's own onboard
   microphone supplies the level, so the macOS app should only control/display
   the device feature; it must not add a Mac microphone dependency. Add a
   Control Center icon when implementing.
2. **Scoreboard** — two three-digit scores plus reset/on-off.
3. **Countdown Timer** — duration plus start/stop.
4. **Stopwatch** — start/stop/reset.

Sleep-control commands remain a separate research question, not part of this
batch. The project's existing warning is based on external reverse-engineering
and generic Divoom mapping, not a bricking event personally observed by this
project's user; do not weaken the send guard or transmit any of those opcodes
without an explicit capture-first test plan and a hardware power-cycle
recovery path.

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
  no longer referenced by the app build at all. Full story, including the
  zstd C-interop mechanics proof, in `dev-notes.md`.
- **Native Bluetooth migration.** `blueutil` has been removed from app setup
  and connection management in favor of public `IOBluetooth`. Scan/pairing
  were physically confirmed; nearby-unpaired discovery and native
  disconnect → RFCOMM-open / reconnect audio remain explicit release checks.

- **Self-update / Sparkle — in progress (2026-07-11).** The app now has a
  pinned SwiftPM/Sparkle update path, embedded repository/branch/channel build
  provenance, first-launch update consent, Preferences/About visibility, and
  a branch-locked signed-feed workflow design. The pre-notarization relaunch
  flow gives the user an explicit, default-checked choice to remove quarantine
  from the verified staged update; it never does so silently. Local universal
  packaging and appcast-generation checks pass. Hosted CI publication passed
  end-to-end in run `29154079898`: both architecture slices, universal DMG,
  signed one-item Personal appcast, immutable update ZIP, and release publish
  all succeeded. First user launch/UI and real in-app update-install
  confirmation remain required. The CI design retains only the newest three
  immutable update releases. See `docs/local/update-strategy.md`; no
  Bluetooth/device behavior changed or was tested here.

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
