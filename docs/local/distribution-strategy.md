# Distribution strategy (fork-local)

## Current release model

MiniToo Toolbox for macOS is the independently maintained **Main-only**
product line. A non-documentation push to `main` runs unit tests, builds
Apple Silicon and Intel slices, assembles a universal app, creates a DMG and a
separate Sparkle update ZIP, and publishes the rolling `main-latest`
prerelease plus an immutable update release.

The former Personal release branch, feeds, tags, releases, compatibility
workflow inputs, and updater bridge were retired on 2026-07-13. Every
pre-rename installation—former Main or Personal—must manually install the
current Main DMG; no legacy build participates in in-app updating.

## Current artifacts and build inputs

- `main-latest` contains the universal `MiniToo Toolbox.app` DMG, SHA-256
  checksum, one-item signed `appcast-main.xml`, matching release notes, and
  the FFmpeg 8.1.2 source archive required by its LGPL distribution.
- Each update is an immutable app-only ZIP on a `main-update-*` prerelease.
  The feed contains only the newest item, and CI retains the three newest
  immutable update releases.
- The app is native Swift/macOS. It bundles FFmpeg for GIF/video decoding and
  vendors zstd source; it does not bundle Python, a virtual environment, or
  PyInstaller output.
- FFmpeg cache entries are an optional speed optimization. The cache key and
  manifest bind architecture, source version, and build recipe; final app and
  release artifacts are never cached.
- Intel FFmpeg uses NASM installed on the Intel hosted runner. This is a known
  mutable build dependency and is covered by the deferred supply-chain plan.

## Established evidence

The release pipeline has already passed end-to-end universal assembly and
publication. The last locally recorded successful Main-only publication is
GitHub Actions run `29262212226` (Main build 3015). Earlier failed CI runs,
Python-helper packaging issues, ZIP-to-DMG migration work, and pre-rename
asset cleanup are resolved history, not release gates.

Commit `aed3e86` subsequently adjusted DMG icon alignment. This repository's
local notes do not record a hosted run for that exact commit, so verify the
published presentation when that build is available rather than restating the
old first-release checklist.

## Remaining release validation

These are deliberate physical observations, not blockers inferred from clean
logs:

- In a fresh install, scan for and select/pair a MiniToo; then relaunch and
  confirm the saved address is used.
- Exercise nearby-unpaired discovery and the full native Bluetooth lifecycle:
  disconnect → RFCOMM-open/control → audio reconnect. The generic link API
  must not be described as an audio-profile control.
- Send a 128×128 still, GIF, short MP4/video, Photo Album still, and
  full-screen 160×128 media from the actual menu UI. These paths are already
  hardware-confirmed; this is normal release regression coverage.
- Inspect a published DMG containing the latest `aed3e86` icon-alignment
  change in Finder. User Finder settings can expose hidden background files or
  consume viewport space; the DMG must not attempt to override those settings.

## CI monitoring rule

The agent that triggers a Main-release workflow owns its outcome: poll that
specific run to success or failure and fetch/diagnose the failing job log in
the same task. Do not hand off a triggered workflow without a terminal result.
If the current surface cannot maintain that monitor, say so before handoff.

## Deferred hardening

Branch protection, least-privilege release separation, immutable Action pins,
FFmpeg digest verification, locked Python release dependencies, and Developer
ID signing/notarization are not silently assumed here. Their priorities and
acceptance checks are maintained in `security-supply-chain-plan.md`.
