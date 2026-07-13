# Branch workflow (fork-local, not upstream contribution policy)

How this fork is managed relative to alvinunreal/divoom-minitoo-osx. Not a
statement of upstream project policy.

## Branches
- `main` (pushed to `fork/main`) — the active, independently maintained
  branch and release line. Cut all new feature branches here.
- `personal` (pushed to `fork/personal`) — preserved only for the one-time
  signed updater bridge; it is no longer a development branch.
- `origin/main` — the upstream comparison point. It intentionally diverges
  from this fork's `main`; do not merge or push to it by routine.

## CI doesn't run for doc-only pushes

`.github/workflows/main-release.yml`'s push trigger has
`paths-ignore: ["**/*.md"]` — a push to `main`
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

## Keep release notes current

`RELEASE_NOTES.md` is the user-facing text for both the `main-latest`
GitHub release and its Sparkle update metadata; it is not a historical changelog
or an internal engineering log. Update it in the same change set as every
user-visible feature, behavior change, limitation, installation/update change,
or material reliability improvement destined for `main`. Describe what a
user can do or needs to know, distinguish hardware-confirmed functionality from
capture-derived/experimental controls, and do not advertise disabled prototypes
as available features. Keep implementation-only changes (refactors, tests,
vendor updates) out unless they materially change the user's experience.

Because Markdown-only pushes intentionally skip the release workflow, a
release-notes-only correction does not publish by itself. Include the note with
the related releasable code whenever possible; if a standalone correction must
reach an existing release/update feed, explicitly request or run the workflow's
`workflow_dispatch` path and monitor that run to completion.

## Git transport vs. GitHub API authentication

The local `fork` remote is the authority for normal source pushes. Its Git
credential (currently HTTPS through macOS Keychain) is independent from the
GitHub CLI's API token and from Codex's GitHub MCP connection. In particular,
an expired `gh auth status` result is **not** by itself a reason to block a
normal, explicitly requested `git push fork personal`.

Before declaring a push blocked, make a read-only transport check such as
`git ls-remote --heads fork personal`; if it succeeds, stage only the intended
paths, commit, and push normally. Use the GitHub MCP connector for repository,
release, and Actions inspection when available. Re-authenticate `gh` only
when a task genuinely requires that local CLI's API access and MCP cannot do
the job. Do not use the MCP contents API to synthesize a replacement remote
commit for local work: that would leave the checkout out of sync with its
branch history.

## PRs to upstream are opt-in, not a default sync step

As of 2026-07-10, opening or updating a PR against
`alvinunreal/divoom-minitoo-osx` is never done automatically as part of
routine sync/compact-prep work — only when the user explicitly asks for it
in that session. Previously, compact-prep would proactively cherry-pick and
push new commits onto an already-open PR branch by default; that is no
longer standing behavior. Commit and push to `main`/`fork/main` as normal;
leave existing PR branches alone unless asked.

## Before opening a PR
- One logical feature per branch/PR.
- Disclose AI-assisted development + human hardware testing in the body.
- Confirm the exact title/body before running `gh pr create`.
- Check `gh pr list --repo alvinunreal/divoom-minitoo-osx` for current
  status rather than trusting a remembered list.

## After merging back into `main`
Grep for duplicate `func` declarations before trusting a clean merge:
`grep -oE '(@objc )?func [a-zA-Z0-9_]+' file.swift | sort | uniq -c | sort -rn`

## Independent-fork policy

`main` is the active independent downstream line. This is a repository and
release-policy change, not a claim of upstream endorsement or a license grant.
Keep upstream credit and do not add a blanket license over upstream-authored
material. The separate clean-room strategy governs later source replacement.

## One-time Personal updater migration

Once the first `main` release exists, dispatch `main-release.yml` from the
preserved `personal` ref with `release_channel=personal-transition`, and
monitor it to a terminal result. Old Personal builds first receive that signed
Personal bridge; it then checks the signed Main feed and accepts only `main`.
Do not delete `personal-latest` or its bridge release until retirement.

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
