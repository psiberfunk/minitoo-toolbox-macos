# MiniToo Toolbox identity migration ledger

## Objective

Move the independently maintained project from its former Divoom MiniToo
identity to **MiniToo Toolbox for macOS**, preserving device selection and
preferences for users who install the renamed app.

This is a checkpointed migration. Each phase must be committed, pushed, and
independently buildable before work starts on the next phase. Do not squash,
rebase, force-push, or mix unrelated feature work into these commits.

## Non-negotiable compatibility invariants

1. The renamed release uses a `CFBundleVersion` above the legacy public
   high-water mark, because Sparkle compares that build number rather than the
   marketing version string. This preserves monotonic release versioning; it
   does not promise an in-app migration from a pre-rename installation.
2. The renamed app imports the old `local.divoom.minitoo` defaults domain once,
   without overwriting values a user has already set in the new app.
3. The old `~/Library/Application Support/DivoomMiniToo` directory moves only
   when `~/Library/Application Support/MiniTooToolbox` does not already exist.
4. Device/protocol terms such as `Divoom*`, Bluetooth device names, and wire
   formats are not cosmetic rename targets. They remain where technically
   accurate.
5. No hardware-affecting behavior may be claimed verified without direct user
   confirmation on a physical MiniToo.

## Phase map and handoff state

### Phase 1 — local app identity and data import (complete: `da3dd3f`)

Scope: Swift package product, bundle/display/executable names, app-support
directory, one-time preference import, DMG settings, CI artifact names,
installation guide, and README rewrite. Keep the GitHub repository name and
current remote URLs unchanged in this phase.

Required checks before commit:

- `swift test`
- `bash -n tools/build-divoom-app.sh`
- YAML parse for `.github/workflows/main-release.yml`
- `git diff --check`
- local build inspection: the bundle name, executable, identifier, and support
  directory must match this document.

Required handoff note: record commit ID, test result, and every intentionally
unchanged old-name reference. Do not use a broad search/replace after this
phase.

### Phase 2 — installed-app migration validation (retired; not performed)

The planned observation of a real pre-rename Main app installing/updating into
the renamed app was not performed. The project deliberately retired the
entire compatibility-updater path: every pre-rename installation must manually
install a current MiniToo Toolbox Main DMG. The renamed app still performs its
one-time import of old preferences and Application Support data after that
manual installation.

### Phase 3 — GitHub repository rename (complete)

Scope: rename to `psiberfunk/minitoo-toolbox-macos`, update local `fork` URL,
verify `origin` remains the upstream comparison remote, and inspect GitHub
Actions/release feeds after the redirect. Do this only from a clean worktree
at a committed migration tip.

Required checks: GitHub default branch remains `main`; old release/feed URLs
redirect; new workflow builds embed the new repository; `main-latest` is
published successfully. Monitor the full workflow to completion.

### Phase 4 — post-rename release and public audit (complete: `3520f51`)

Scope: publish one renamed Main release, check release asset/appcast URLs,
update public GitHub description/topics, and run a focused stale-public-name
audit. Retain historical/protocol/upstream references that are accurate.

Completed evidence: repository renamed; `fork` points to the new repository;
the former feed URL returned a 301 to the new `main-latest` appcast; workflow
run `29255939905` completed successfully; the appcast is `MiniToo Toolbox`
and points to the new immutable update archive. Workflow run `29256371448`
then completed successfully and reduced `main-latest` to the current
MiniToo Toolbox DMG, checksum, release notes, appcast, and FFmpeg source.
The GitHub description is “Native macOS controls and media tools for the
Divoom MiniToo.” A focused public-reference audit found only intentional
upstream credit, legacy-user bridge guidance, and release-cleanup rules.

The neutral README acknowledgement follow-up is `4410da4`; it is Markdown-only
and intentionally did not publish a new application release. The former
Personal artifacts were later retired in Phase 4a.

### Phase 4a — legacy Personal updater retirement (complete)

An attempted Personal-to-renamed-App bridge exposed a Sparkle limitation: a
renamed archive cannot replace a differently named installed bundle using the
plain installer. Rather than preserve a multi-stage updater path for two
remaining users, the project retired that path on 2026-07-13.

The retired branch, migration-only feeds and releases, bridge-only workflow
inputs, and bridge-only app metadata were removed. Every pre-rename user must
make a one-time manual installation of a current MiniToo Toolbox Main DMG.
Normal releases remain Main-only, with the standard `MiniToo Toolbox.app`
archive directory and 3000+ build-number floor.

## Concurrent-agent rules

- Before starting, run `git status --short --branch`, read this ledger, and
  identify the current phase from committed history—not from memory.
- Work only on files assigned to the current phase. Feature agents may work on
  separate branches, but must branch from the latest committed `main` and must
  not edit package identity, build/release workflow, update controller,
  installation guide, or README during Phases 1–4.
- Stage exact paths; never use `git add -A`. Preserve the unrelated untracked
  `docs/local/assets/` directory.
- Before any merge/rebase, compare changes against the migration commit range
  and resolve identity-related conflicts manually. Never silently prefer an
  old app name, bundle ID, artifact name, or support path.
- If context compacts or a new agent resumes, begin with this file, `git log
  --oneline --decorate -12`, `git status --short --branch`, and the release
  workflow status. Continue only from a committed checkpoint.
