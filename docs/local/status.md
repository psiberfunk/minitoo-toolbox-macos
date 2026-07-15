# Status (fork-local)

Authoritative current-state tracker for the independently maintained `main`
branch. Last reconciled 2026-07-14 against committed work through `aed3e86`
(DMG icon alignment). Detailed investigation history belongs in `dev-notes.md`;
this file deliberately does not retain superseded release gates or past test
failures as open work.

## Product and release state

| Area | Current state |
|---|---|
| Product identity | **MiniToo Toolbox for macOS.** The independently maintained `main` product line is separate from upstream. |
| Distribution and updates | **Main-only.** `main-latest` publishes a signed one-item Sparkle feed and a universal DMG. Every pre-rename build—including former Main and Personal builds—requires a one-time manual installation of a current Main DMG; no compatibility updater path remains. The last recorded hosted publication is run `29262212226`, Main build 3015. |
| Shipped runtime | Native Swift/macOS app and daemon; no bundled Python runtime. FFmpeg remains bundled for GIF/video decoding and vendored zstd handles compression. |
| Latest committed packaging change | `aed3e86` fixes DMG icon alignment. Its hosted-release outcome is not recorded in this repository's local notes. |

## Completed features

| Feature | Current state |
|---|---|
| Setup and identity | In-app Bluetooth scan/select; selected MAC is cached in `UserDefaults` and never hardcoded. Scan/pairing is hardware-confirmed. |
| Connection/status UI | The menu separates the generic Bluetooth link, local CoreAudio route, and end-to-end control health. It starts/reuses the control service non-disruptively and has a one-shot stale-RFCOMM recovery. A fresh launch reaching Ready and controlling brightness was hardware-confirmed; see **Remaining validation** for the narrow UI checks left. |
| Brightness and screen on/off | Done, hardware-tested. |
| Custom face selection | Slots 1–3 (`ClockId` 984/986/988) can be selected and were re-confirmed after the native Swift port. The slots are empty; uploading face content is not understood. |
| White Noise | Done: per-channel sliders, on/off control, capture-derived device-state readback, and optional quiet refresh. Its display-mode behavior is a MiniToo UX quirk, not evidence of a failed transport command. |
| Photo Album | Done for still images. The official app does not currently support adding video here; the earlier multi-frame/video attempt was removed. |
| Send Media | 128×128 and full-screen 160×128 stills, GIFs, and video work. The packet-file race fix and native media port were hardware-confirmed; one isolated non-reproducible full-screen MP4 failure remains documented as an RFCOMM-timeout suspect, not an active regression. |
| Atmosphere | Done: 21 backgrounds, six text effects, capture-derived names, state readback, and quiet optional refresh. Mac-originated live lyrics are shelved; see **Shelved/deferred**. |
| Device Settings | Temperature/date/clock format, Bluetooth auto-reconnect, remembered volume, auto power-off, and notification level are implemented. Values are last-sent preferences because this protocol provides no device readback. |
| Noise Meter | Capture-derived and hardware-confirmed. Uses the MiniToo microphone only; no numeric level readback is established. |
| Countdown Timer | Capture-derived and hardware-confirmed for Start and Stop/Reset. |
| Stopwatch | Capture-derived and hardware-confirmed for Start, Pause, and Reset. |
| Time Sync | Manual custom/current-Mac-time sync and opt-in automatic sync are hardware-confirmed. The app sends only the capture-derived raw `0x18` setter; it does not claim clock readback. |
| Games / Pixel Slot | The Pixel Slot launcher is capture-derived and hardware-confirmed. Starting/playing and exiting remain physical-knob actions; no other game command is inferred. |

## Active capture and implementation work

Only the items below are current feature work. Do not enable a device command
from APK/static analysis alone: first obtain an Android Bluetooth HCI capture,
then port the observed traffic, then obtain direct user hardware confirmation.

1. **Scoreboard:** the disabled UI prototype reflects observed behavior, but no recoverable packet body exists. Capture the command before enabling it.
2. **Alarms:** the disabled prototype has no writable command yet. Capture list/read, slot write/edit, enable/disable, and any supported deletion/reset behavior; then perform a deliberate near-future alarm test on the MiniToo.
3. **Further Games:** capture each official-app launcher and any return/exit behavior individually. Do not derive game IDs from APK code. Pixel Slot needs no further protocol work unless its launcher regresses.
4. **Countdown pause:** remain unsupported until a clean capture isolates a distinct pause/resume command or device event. Start and Stop/Reset are the complete currently supported surface.
5. **Countdown field usability:** the revised bounded `mm:ss` field and stepper
   need a quick user usability observation. This is a UI follow-up only; the
   underlying timer commands are already hardware-confirmed.

Sleep-control commands are outside this batch. They remain prohibited without an
explicit capture-first test plan and a power-cycle recovery path.

## Remaining validation and maintenance

- **Status UI:** confirm the rebuilt CoreAudio route presentation in the app
  (selected/available/unknown) and keep the automatic stale-RFCOMM recovery
  claim bounded to the directly observed fresh-launch recovery. Do not infer
  audio playback or another host's ownership from the generic Bluetooth link.
- **Native Bluetooth release checks:** nearby-unpaired discovery and the full
  disconnect → RFCOMM-open → audio-reconnect lifecycle still need deliberate
  physical release-check observations. This does not invalidate the confirmed
  scan/pairing and control-recovery behavior above.
- **DMG presentation:** verify the published DMG containing the latest
  icon-alignment change when a release run is available; do not resurrect the
  already-resolved pre-release packaging gates.

## Shelved or deliberately deferred

- **Device rename (`0x75`):** capture-derived but shelved on
  `shelved/device-rename`; persistence is flaky. It is not current feature
  work.
- **Mac-originated live lyrics:** shelved. macOS has no supported way for this
  app to provide MiniToo AVRCP metadata while normal audio is connected; a
  Linux bridge/Android companion is outside product scope. Revisit only if
  macOS or MiniToo behavior changes.
- **Animated media preview playback:** the preview intentionally displays the
  first encoded frame only. Playback in the preview is a separate future UI
  idea, not a media-send defect.
- **Supply-chain hardening:** deliberately deferred. The phased plan is in
  `security-supply-chain-plan.md`; it is not part of the active feature batch.
- **Developer ID signing and notarization:** future distribution hardening;
  current releases are ad-hoc signed with the explicit verified-update
  quarantine option.

## Documentation routing

- `dev-notes.md` — chronological experiments, captures, resolved incidents,
  and product ideas.
- `minitoo-toolbox-migration.md` — the completed identity-migration ledger,
  including the retired compatibility-updater experiment.
- `distribution-strategy.md` and `update-strategy.md` — current release and
  updater design.
- `security-supply-chain-plan.md` — deferred security hardening backlog.
