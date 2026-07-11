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
