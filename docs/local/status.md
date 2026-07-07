# Status (fork-local)

Current state of each feature on `personal` — includes work still sitting
in unmerged upstream PRs, so this does NOT represent alvinunreal/main's
actual state. Edit in place when status changes; this is a table, not a
log.

| Feature | Status |
|---|---|
| Brightness (`0x74`) | Done, hardware-tested. |
| Screen on/off | Done, hardware-tested. |
| Custom faces 1-3 (`ClockId` 984/986/988) | Selection works, hardware-tested. All 3 slots are currently **empty** — nothing has ever been uploaded into them. How to populate a slot is unknown (see `dev-notes.md`). |
| White Noise | Done. Per-channel sliders + on/off toggle, real device-state readback, quiet auto-refresh with a user toggle. |
| Photo Album | Done, stills only. Multi-frame/video was implemented and hardware-tested but reverted — the official Divoom app itself doesn't support adding video to this feature on the current app version either. |
| Atmosphere | Done. 21 backgrounds + 6 text effects, all real on-device names known, state readback works, quiet auto-refresh. `TextEffect` produced no visible change tested with silence playing — unconfirmed whether it needs active music or isn't working. |
| Full-screen send (160×128) | Done. Panel is 160 wide × 128 tall, not square; square sends are left-justified, not centered. |
| Device MAC address | Done. No longer hardcoded anywhere — discovered via in-app Bluetooth scan, cached in `UserDefaults`. |
| Device rename (`0x75`) | **Shelved**, code moved to `shelved/device-rename` branch (off `personal`). Protocol verified byte-for-byte against a real capture, but on-device persistence of a new name is unreliably flaky for reasons still unknown. Full story in `dev-notes.md`'s "Known gotchas". No PR opened. |
| Alarms (`0x43`/`0x42`) | APK-decoded only, never hardware/capture-verified. |
| Games (`0xa0`/`0x17`/`0x21`/`0x88`) | Same as Alarms. |
| Device Settings (`Sys/SetConf`) | **Hardware-tested (2026-07-07)** end-to-end from this app's own UI: temperature unit, date format, clock format (including the `Time24Flag` 0/1↔12h/24h mapping itself), Bluetooth auto-reconnect, remember-power-on-volume, auto power off all confirmed working against a real MiniToo. Notification sound (level slider) confirmed reachable, not independently confirmed audible. No device-side state readback exists for this command (confirmed by direct testing, not just capture absence) — screen caches last-sent values in `UserDefaults` instead, with a `(?)` tooltip explaining that's not a live read. "Shake Shake" and "Tap and Play" confirmed **not** BT-transmitted — Android-local only, not implemented. Known MiniToo firmware quirk: its own on-screen settings menu can show stale text after a change until backed out and re-entered (documented in README.md). See PROTOCOL.md's "Device Settings" section. |
| App icon | Done (2026-07-07). `assets/AppIcon.icns` wired into the bundle via `CFBundleIconFile`, confirmed rendering correctly in Finder (icon-view + Get Info). First pass (thin coloring-book line art) was unreadable at 16-32pt; measured actual rendered sizes side-by-side and found two fixes needed: bold, high-contrast linework (3x stroke width, simplified fine detail) and a tight crop (content filling ~90% of the 1024 canvas, not ~74%) — a solid dark glyph on the screen is what actually survives downscaling, thin outline detail doesn't. Current source (`assets/AppIcon-source.png`) is a Gemini-refined redraw at fairly low native resolution (~244×297, cropped from a multi-icon contact sheet) upscaled to fill the icon canvas — usable but a higher-res single export would sharpen 512/1024pt renders if revisited. Regen steps in README.md. |

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
