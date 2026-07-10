# Distribution strategy (fork-local)

## Goal

Publish a self-contained universal macOS app from every push to `personal`.

## Stepwise rollout

1. Build arm64 and x86_64 Swift slices, freeze the Python-backed media helper
   once per architecture, and assemble a universal app. **Implemented; local
   compile/package checks passed.**
2. Replace the external `blueutil` CLI with public IOBluetooth APIs for scan,
   pairing, disconnect/reconnect, and connection-state checks. **Implemented
   in code; the scan deliberately distinguishes a real nearby inquiry from
   saved pairing records and prompts when Bluetooth is off. **Scan/pairing
   physically confirmed; nearby-unpaired discovery and audio lifecycle still
   require final physical confirmation.**
3. Bundle FFmpeg as a separate LGPL-only executable. The release workflow
   builds it with GPL/nonfree features disabled and attaches the exact source
   archive with each release. **Implemented in workflow; needs first CI run.**
4. Publish the rolling `personal-latest` prerelease only after the local
   hardware checklist below passes. The first push is also the first real CI
   validation of both hosted macOS architectures, frozen helpers, FFmpeg
   builds, release permissions, and universal assembly.

### First CI failure and correction

Run `29100401008` failed before release assembly for two unrelated reasons:
the Apple Silicon package script treated the expected absence of a signing
identity as fatal under `pipefail`, and the Intel FFmpeg configure expected
NASM, which the hosted runner lacks. The signing lookup now permits the
existing ad-hoc fallback; Intel CI installs NASM before building FFmpeg, which
retains its normal optimized x86 path. Native app build logs are retained for
seven days on future failed runs.

## Required physical checklist

- New install: first-run scan finds the MiniToo.
- New install: select/pair a device and relaunch; cached address is used.
- Audio is connected: start/restart daemon disconnects audio and opens RFCOMM.
- Reconnect Audio works afterward.
- Send a still image, GIF, and short MP4/video from the menu UI.
- Confirm the app works without Homebrew `blueutil`, Python, or FFmpeg.
- Re-test normal 128×128 still and MP4 send after the packet-reuse change.
- Do **not** test Send Media full-screen mode: it is quarantined after a
  reported device crash. An earlier app version worked, so investigate by
  diffing that known-good app's generated packet stream against the current
  one for identical input; a new Android capture is not the remediation path.
  Photo Album's 160×128 JPEG path is separate and has been physically
  confirmed working.

Never call Bluetooth hardware behavior verified from logs alone. Record the
user's visual/physical result in `docs/local/status.md` before release.
