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

## Before opening a PR
- One logical feature per branch/PR.
- Disclose AI-assisted development + human hardware testing in the body.
- Confirm the exact title/body before running `gh pr create`.
- Check `gh pr list --repo alvinunreal/divoom-minitoo-osx` for current
  status rather than trusting a remembered list.

## After merging back into `personal`
Grep for duplicate `func` declarations before trusting a clean merge:
`grep -oE '(@objc )?func [a-zA-Z0-9_]+' file.swift | sort | uniq -c | sort -rn`

## Historical note
Every PR branch used to require swapping the real device MAC for a
placeholder before pushing. Obsolete now — no file hardcodes a MAC anymore.
