# Distribution strategy (fork-local)

## Goal

Publish a self-contained universal macOS app from every push to `personal`.

## Future product identity (deferred)

Before broad distribution, evaluate whether this fork should receive a new app
name and promote its active `personal` line to the fork's `main` branch. That
is a governance/identity transition, not a build-system rename: it requires
legal distribution-rights review, upstream attribution, a bundle-ID and
UserDefaults migration plan, release/workflow retargeting, and an explicit
decision not to imply upstream endorsement or takeover. The detailed checklist
lives in `docs/local/branch-workflow.md`.

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
   archive with each release. **Implemented and published by the first
   successful CI release.**
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

The corrected second run (`29112757315`) successfully built both architecture
slices, including Intel FFmpeg with NASM. It then failed only in universal
assembly because the workflow attempted to rename the extracted Intel app to
the exact same path. That no-op is removed; the next push validates assembly,
ad-hoc signing, artifact upload, and release publication. The third run
(`29113738061`) completed successfully on 2026-07-10 and published the
universal ZIP, SHA-256 file, and matching FFmpeg source archive to the rolling
`personal-latest` prerelease.

### Later CI optimization: deterministic dependency caches

After a complete release run is green, cache the expensive, deterministic
parts of the hosted build. The priority is the per-architecture compiled
FFmpeg binary (and its source archive), keyed by architecture, FFmpeg version,
an explicit cache revision, and the hash of `tools/build-ffmpeg.sh`. Add the
normal pip download cache as well. Do **not** cache `.venv`, the FFmpeg build
tree, Homebrew, or final app/release artifacts: those are runner/path-sensitive,
too large for the value, or are already handled as artifacts. The build script
must validate a restored FFmpeg binary and build normally on a cache miss.
Increment the cache revision to deliberately invalidate all FFmpeg caches.
Caching is an optional speed-up, never a dependency for a reproducible build.

### CI monitoring rule

The agent that triggers a personal-release workflow owns its outcome: it polls
that run using concise status checks until success or failure, then immediately
retrieves and diagnoses any failing job log. It must not simply start a build
and rely on the user to return with the result. This is also a standing
workspace instruction in `../AGENTS.md` so it applies in later sessions and to
all agents working in this project. If an agent cannot remain active or create
a persistent monitor in its current surface, it must state that limitation
before handing off.

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
