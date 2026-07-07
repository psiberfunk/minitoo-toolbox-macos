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

## Upstream docs housekeeping
PR #11's description was updated with a root-cause sentence (no branch diff
change). PR #16 is a new standalone upstream docs PR carrying the
custom-face dead-ends and Bluetooth troubleshooting notes. Device-rename
docs stay local-only until that feature gets its own PR.
