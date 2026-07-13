# MiniToo Toolbox identity migration ledger

## Objective

Move the independently maintained project from its former Divoom MiniToo
identity to **MiniToo Toolbox for macOS**, while preserving installed users'
device selection, preferences, and signed update path.

This is a checkpointed migration. Each phase must be committed, pushed, and
independently buildable before work starts on the next phase. Do not squash,
rebase, force-push, or mix unrelated feature work into these commits.

## Non-negotiable compatibility invariants

1. Existing Personal installations retain their already-published signed bridge
   until an old Personal app has updated into Main.
2. Existing Main installations continue to reach their signed `main` feed when
   the GitHub repository moves; GitHub's old URL redirect is relied on but must
   be tested from an installed app before old release assets are retired.
3. The renamed app imports the old `local.divoom.minitoo` defaults domain once,
   without overwriting values a user has already set in the new app.
4. The old `~/Library/Application Support/DivoomMiniToo` directory moves only
   when `~/Library/Application Support/MiniTooToolbox` does not already exist.
5. Device/protocol terms such as `Divoom*`, Bluetooth device names, and wire
   formats are not cosmetic rename targets. They remain where technically
   accurate.
6. No hardware-affecting behavior may be claimed verified without direct user
   confirmation on a physical MiniToo.

## Phase map and handoff state

### Phase 1 — local app identity and data import (current)

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

### Phase 2 — installed-app migration validation

Scope: use a real installed pre-rename Main app to install the renamed build.
Confirm preferences/device address, update consent, UI preferences, and logs
survive; then confirm Main feed lookup works with the changed app identity.

This requires user observation. Until it is complete, do not delete old Main
release assets or claim cross-identity updating works.

### Phase 3 — GitHub repository rename

Scope: rename to `psiberfunk/minitoo-toolbox-macos`, update local `fork` URL,
verify `origin` remains the upstream comparison remote, and inspect GitHub
Actions/release feeds after the redirect. Do this only from a clean worktree
at the committed Phase 2 tip.

Required checks: GitHub default branch remains `main`; old release/feed URLs
redirect; new workflow builds embed the new repository; `main-latest` is
published successfully. Monitor the full workflow to completion.

### Phase 4 — post-rename release and public audit

Scope: publish one renamed Main release, check release asset/appcast URLs,
update public GitHub description/topics, and run a focused stale-public-name
audit. Retain historical/protocol/upstream references that are accurate.

### Phase 5 — retirement decision (explicit later decision)

After an agreed observation period and a successful old-install update test,
choose a retirement date for `personal-latest`, `personal-update-4`, and the
preserved `personal` branch. Do not remove them earlier.

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
