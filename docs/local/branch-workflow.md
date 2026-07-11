# Branch workflow (fork-local, not upstream contribution policy)

How this fork is managed relative to alvinunreal/divoom-minitoo-osx. Not a
statement of upstream project policy.

## Branches
- `main` — kept clean, matches `origin/main`. Cut new feature branches here
  when possible.
- `personal` (pushed to `fork/personal`) — daily-use branch, everything
  merged in.
- `fork/main` (GitHub) — untouched mirror of upstream `main`.

If a new branch depends on something only merged into `personal`, cut it
from `personal`'s tip instead of clean `main`, and say so in the PR body.

## CI doesn't run for doc-only pushes

`.github/workflows/personal-release.yml`'s push trigger has
`paths-ignore: ["**/*.md"]` (added 2026-07-11) — a push to `personal`
that only touches `.md` files (README, PROTOCOL.md, anything under
`docs/local/`, `THIRD_PARTY_NOTICES.md`, `RELEASE_NOTES.md`) doesn't
trigger a build/release run at all. A commit that touches even one
non-`.md` file (source, `Tests/`, the workflow file itself, etc.)
alongside doc changes still runs normally — the skip only applies when
*every* changed file matches the ignore pattern. `workflow_dispatch`
still works regardless, for the rare case of wanting a fresh release
build/publish for a pure doc change (e.g. to update the bundled copy of
PROTOCOL.md inside the app resources without any code change). If a
future session notices CI "didn't run" after a docs-only push, this is
expected behavior, not a broken workflow — check `paths-ignore` before
assuming something's wrong.

## PRs to upstream are opt-in, not a default sync step

As of 2026-07-10, opening or updating a PR against
`alvinunreal/divoom-minitoo-osx` is never done automatically as part of
routine sync/compact-prep work — only when the user explicitly asks for it
in that session. Previously, compact-prep would proactively cherry-pick and
push new commits onto an already-open PR branch by default; that is no
longer standing behavior. Commit and push to `personal`/`fork/personal` as
normal; leave existing PR branches alone unless asked.

## Before opening a PR
- One logical feature per branch/PR.
- Disclose AI-assisted development + human hardware testing in the body.
- Confirm the exact title/body before running `gh pr create`.
- Check `gh pr list --repo alvinunreal/divoom-minitoo-osx` for current
  status rather than trusting a remembered list.

## After merging back into `personal`
Grep for duplicate `func` declarations before trusting a clean merge:
`grep -oE '(@objc )?func [a-zA-Z0-9_]+' file.swift | sort | uniq -c | sort -rn`

## Future independent-fork transition (not approved or scheduled yet)

The current `personal` branch is the active daily-use line, but this fork is
not yet represented as a renamed successor or a takeover of upstream. If the
fork eventually becomes its own maintained product, plan the transition as one
intentional change set rather than gradually implying it:

1. Confirm legal distribution rights first. As of 2026-07-10, the upstream
   repository's root listing has no `LICENSE` file. Keep upstream attribution,
   do not claim upstream abandonment or endorsement, and do not add a blanket
   license that purports to cover upstream-authored code without permission.
2. Choose a new app/project name and update the visible app identity,
   `CFBundleIdentifier`, release assets, README wording, and support/log paths.
   Include a UserDefaults migration so existing device-address preferences are
   not silently lost when the bundle identifier changes.
3. Promote the active integrated line from `personal` to this fork's `main`,
   make it the GitHub default branch, and retarget the release workflow from
   `personal` to `main`. Preserve an untouched upstream-tracking branch and
   the `origin` remote for future comparison.
4. Describe the result accurately: an independently maintained downstream
   fork, with upstream credit and no claim of official succession unless the
   upstream author grants it.

Until those gates are deliberately satisfied, retain the present names and
branch arrangement. This is a future to-do, not authorization to rename,
relicense, or publish a differently branded app now.

## Historical note
Every PR branch used to require swapping the real device MAC for a
placeholder before pushing. Obsolete now — no file hardcodes a MAC anymore.

## Concurrent sessions in the same working tree

This project runs both Claude and Codex sessions against the same
`divoom-minitoo-osx` checkout, sometimes at the same time. Two distinct
failure modes have come up, with two different fixes:

**Before starting work — another session's uncommitted WIP is sitting in
the tree.** Don't try to work around it in place or guess which parts are
"safe" to ignore, especially if it touches the same build script/system
you need to test against. `git stash push -u -m "<label>" -- <exact
paths>` (confirm exact paths via `git status --short` first, so you stash
only their files, not your own new/untracked work mixed into the same
directory), do your work against the clean committed baseline, then
restore their stash after your own commits land. Don't auto-merge their
stash back in yourself — the conflicts are usually structural, and only
the other session has the context to resolve them correctly. Instead,
leave a mechanism-level handoff note (not just "there will be conflicts,"
but "your `Package.swift` needs these N files added" specifics) so they
can act without re-deriving the analysis.

**After the fact — a concurrent session's own commit swept up your
uncommitted changes.** Don't assume a clean `git status` mid-task means
nothing happened: a concurrent session's auto-commit behavior (or a broad
`git add -A`/`git commit -a`) can bundle your edits into its own commit
without you ever running `git commit`. Watch for `git status` reporting
the branch already matching its remote, or "ahead of fork by N commits,"
when you don't recall pushing — that's the tell. If it happens:
1. Diff every affected file against what you actually intended (usual
   outcome: content is fine, just misattributed/bundled, not corrupted).
2. To split a mixed commit: create a temp branch from the last
   known-clean commit, `git checkout <mixed-commit> -- <exact paths for
   commit A>` and commit, repeat for commit B's paths, cherry-pick any
   commits that were already single-purpose.
3. Before touching the real branch, verify the split is a pure
   reorganization: `git diff <old-tip> <new-tip>` must be empty.
4. Move the branch to the new tip and push with `--force-with-lease`
   (re-fetch immediately before pushing to catch a second concurrent
   push), never plain `--force`.
5. Force-pushing shared history needs the user to say "force push"
   explicitly — a vaguer "yes, fix it" is correctly insufficient consent
   for this specific action; don't route around that gate.
6. Send the other session a handoff: what happened, that its content is
   intact (just in its own commit now), and that its local view of the
   branch is stale post-force-push (fetch+reset, don't push again from
   the old tip).

Full incident writeup (2026-07-11, a Codex supply-chain-review commit
swept up this session's zstd-decompress test changes): `dev-notes.md`'s
"Untangling a concurrent session's accidental commit" section.
