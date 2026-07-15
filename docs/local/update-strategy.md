# Self-update strategy (Main channel)

## Current implementation

MiniToo Toolbox uses Sparkle 2 for update discovery, archive verification,
replacement, and relaunch. It does not use GitHub's generic “latest release”
API and does not implement a home-grown downloader.

Every CI release embeds its repository, branch, channel, feed URL, commit, and
build number in `Info.plist`. The updater accepts only the embedded Main feed
and channel; its signed appcast contains one newest compatible item and points
to an immutable app-only update ZIP. Preferences exposes the build provenance,
automatic-update preference, and **Check for Updates…**.

The active release target is `psiberfunk/minitoo-toolbox-macos` / `main`:

- The rolling `main-latest` prerelease contains the user-facing universal DMG,
  appcast, and current release notes.
- Each Sparkle archive is published separately as a `main-update-*` immutable
  prerelease. CI retains the current archive and two preceding archives.
- The app asks once whether to enable automatic checks. Download, install, and
  relaunch always remain user-directed.
- During the ad-hoc-signing period, the user may explicitly choose to remove
  quarantine from the verified replacement app before relaunch. The operation
  is scoped to that app, occurs only after Sparkle verification, and is never
  silent.

Every pre-rename build—former Main or Personal—must manually install a current
Main DMG. The compatibility updater experiment is retired; no legacy build is
an in-app update client. See `minitoo-toolbox-migration.md`.

## Established evidence

On 2026-07-11, hosted run `29154079898` passed the original end-to-end
universal build, signed appcast, immutable update archive, and publication
flow. The user directly confirmed first-launch update consent, provenance UI,
and a real in-app update: the initial DMG install needed Gatekeeper clearance,
while the verified in-app update did not require another clearance.

After the Main-only identity transition, the locally recorded hosted
publication is run `29262212226` (Main build 3015). Earlier Personal bridge
experiments and migration-only feeds/releases are retired history, not a
fallback update path.

## Deliberate limits and future work

- No dedicated guard yet prevents choosing relaunch during an active media
  transfer. Until it exists, the UI must not claim this case is handled.
- Developer ID signing, hardened runtime review, notarization, and ticket
  stapling will replace the transitional quarantine choice when available.
- The Sparkle private key is currently a repository-level GitHub Actions
  secret. Separating unprivileged CI from approval-gated signing/publishing is
  the highest-priority deferred security work; see
  `security-supply-chain-plan.md`.

No Bluetooth protocol command is part of the update mechanism. An updater
success cannot verify any MiniToo hardware behavior.
