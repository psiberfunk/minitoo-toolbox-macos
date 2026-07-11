# Self-update strategy (Personal channel)

## Goal

Let an installed Divoom MiniToo app update directly to the newest **compatible
build from the same repository and channel it was built from**.  It must never
silently jump from the Personal fork/channel to upstream, `main`, or a future
renamed channel.

The initial target is the current `psiberfunk/divoom-minitoo-osx` / `personal`
prerelease channel.  A later project/branch rename is an explicit migration,
not an automatic source change.

## Chosen approach

Use Sparkle 2 for macOS update discovery, archive verification, replacement,
and relaunch.  Do not implement a home-grown GitHub downloader/updater.

Sparkle receives a single branch-specific HTTPS appcast.  The `personal`
appcast describes only the newest Personal release, so a user jumps directly
to the current build; it is not a sequential upgrade path.  Release archives
will have immutable URLs internally to avoid an overwrite/cache race, even
though the user-facing channel is simply "latest Personal".

## Build identity and branch lock

Every release build will embed these Info.plist values, supplied explicitly by
CI (with sensible local-development fallbacks):

- `DivoomSourceRepository` — e.g. `psiberfunk/divoom-minitoo-osx`
- `DivoomSourceBranch` — e.g. `personal`
- `DivoomUpdateChannel` — e.g. `personal`
- `DivoomUpdateFeedURL` — only that channel's appcast URL
- `DivoomBuildCommit` and `DivoomBuildRun`

The signed feed URL, Sparkle public key, and Sparkle channel filter are
embedded in the build, so the updater only accepts the branch-specific channel
it was built for. The app does not use GitHub's generic "latest release" API.

Preferences will show an About & Updates section with the displayed version,
build, source repo, source branch/channel, short commit, and a manual
"Check for Updates…" action.

## User experience

On first normal launch, ask whether to enable automatic updates.  The primary
choice is **Enable Automatic Updates**; **Not Now** is remembered and can be
changed later in Preferences.  When enabled, checks are quiet and deferred
until startup has settled. There is no automatic installation or relaunch: an
update installs only after the user chooses to restart. A dedicated
active-media-send install guard is not yet implemented or tested, so do not
select restart while a transfer is active.

The standard install dialog will say which version and channel were verified.
It offers a default-checked, explicit transitional option for ad-hoc builds:

> Remove macOS download quarantine from this verified update

This is not described as a permission fix or as Apple developer trust.  On a
user-approved install only, and only after archive signature + repo/channel
validation, the short-lived updater helper may clear
`com.apple.quarantine` on the newly staged app bundle.  It never operates on
arbitrary paths and never runs silently.  If it is unchecked, the update can
still install but the user may need macOS's normal Gatekeeper approval.

If an app location requires replacement authorization (normally a protected
`/Applications` install), macOS may request the user's password.  A DMG is
read-only and is never updated in place; supported installation locations are
`/Applications` and `~/Applications`.

## Signing rollout

The verified, explicit quarantine option is a temporary bridge while releases
are ad-hoc signed.  It cannot provide the stable identified-developer trust
that Gatekeeper gets from a Developer ID certificate.

The long-term release path is Developer ID Application signing, hardened
runtime/appropriate entitlements, notarization, and ticket stapling.  Once
that is live and tested, the transitional checkbox is hidden because Sparkle's
normal signed update path becomes seamless.

## Release pipeline

Keep the styled DMG for first installation.  Add a separate app-only universal
update ZIP and a signed `appcast-personal.xml` feed.  For the lightweight
initial implementation, the stable branch-specific HTTPS feed is an asset on
the rolling `personal-latest` GitHub release.  It contains only the newest
Personal item and points to that item's immutable update-release asset.

The Sparkle Ed25519 private key is stored only as a GitHub Actions secret; the
public key is embedded in the app.  CI creates a per-build immutable update
asset, signs it, updates the one-item Personal feed, and retains the existing
`personal-latest` prerelease DMG for people who download manually.

### Retention

Immutable update URLs are an implementation detail, not an archive.  After a
successful publish, CI keeps only the current channel update release plus the
two immediately preceding channel update releases.  It deletes older
channel-specific update releases *and their tags*, never the rolling
`personal-latest` release and never unrelated releases.  Keeping three gives
an in-flight updater a short safety window without letting GitHub release
storage grow indefinitely.  CI workflow artifacts for update packaging use a
short retention period as well; the existing FFmpeg cache remains governed by
GitHub's normal cache eviction rather than being copied into every release.

## Implementation and test order

### Build architecture decision

Move Swift source compilation from ad-hoc direct `swiftc` invocations to a
small, pinned Swift Package now. Keep `tools/build-divoom-app.sh` as the
outer packager: it continues to assemble the `.app`, include FFmpeg, write
Info.plist metadata, sign, and make the DMG. The shipped app has no Python
runtime; vendored zstd is a SwiftPM C target alongside the native Swift media
pipeline.

This is deliberately **not** an Xcode-project migration.  SwiftPM provides
reproducible Sparkle dependency resolution, target separation (menu app,
daemon, and future updater helper), and a checked-in `Package.resolved`; the
shell packager remains the project-specific distribution layer.

1. Add the Swift Package, build identity metadata, and the Preferences/About
   UI.
2. Integrate a pinned Sparkle 2 framework through SwiftPM and verify universal
   packaging first.
3. Add consent, automatic/manual checking, safe defer/restart behavior, and
   the explicit ad-hoc quarantine option.
4. Extend CI to publish signed update ZIPs and a Personal-only appcast.
5. Test: disabled/enabled consent; offline/manual checks; wrong-channel and
   tampered feed rejection; `/Applications` and `~/Applications`; DMG
   relocation guidance; no update during a media send; relaunch/device-cache
   persistence; fresh-Mac Gatekeeper behavior.

No Bluetooth protocol command is part of updating.  Hardware behavior is not
changed by this work.

## Progress record

- **2026-07-11:** Added `Package.swift`/`Package.resolved`, pinning Sparkle
  2.9.4 and retaining the native-media/zstd targets. The app packager builds
  the menu app and daemon per architecture through SwiftPM, embeds
  `Sparkle.framework`, and writes build provenance plus Sparkle configuration
  into `Info.plist`.
- **2026-07-11:** Added `DivoomBuildInfo`, `DivoomUpdateController`, the
  first-launch consent dialog, menu/manual check, and Preferences About &
  Updates section. Automatic checks default on only after user consent;
  downloads/restarts remain explicitly user driven during the ad-hoc phase.
- **2026-07-11:** Extended the Personal workflow to create a signed
  one-item appcast and immutable update ZIP, publish the feed on
  `personal-latest`, and retain three `personal-update-*` releases. Local
  universal bundle and appcast-generation rehearsals passed. Hosted release
  run `29154079898` then passed end-to-end: both native slices, universal
  assembly, signed appcast, immutable update ZIP, and rolling-release publish.
  The user then confirmed the first-launch/UI flow and a real in-app update:
  Gatekeeper clearance is needed once for the initial DMG installation, while
  subsequent verified in-app updates relaunch without another Gatekeeper step.
  Remaining hardening is Developer ID signing and notarization; the
  active-media-send restart guard remains an explicit future UX safeguard.
