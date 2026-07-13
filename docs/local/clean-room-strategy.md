# Clean-room replacement strategy (private planning)

## Purpose and boundary

This is a contingency plan for replacing inherited source if upstream licensing
rights remain unclear. It is not legal advice, does not declare the current
tree clean, and does not authorize removal, relicensing, or publication. Keep
the existing upstream attribution and notices until counsel approves a change.

The target is a demonstrably independent implementation whose behavior is
derived from lawful external observations, public platform documentation, and
our own tests—not from copying or translating the inherited source.

## Governance before coding

1. Freeze an evidence snapshot: commit IDs, repository metadata, notices,
   existing release artifacts, and a manifest classifying each file as
   inherited, independently authored after the fork, third-party, generated,
   or unknown. Preserve it privately and do not rewrite history.
2. Ask qualified counsel to set the actual clean-room boundary, review the
   upstream provenance, and approve the planned notices, project identity, and
   redistribution position. A missing upstream response is not permission.
3. Create a separate repository and access-controlled specification archive.
   The implementer must not be given the inherited source, its commit history,
   or line-by-line behavioral descriptions extracted from it.
4. Assign distinct roles: a specification/evidence team that may inspect the
   old tree; an implementation team that may not. Keep dated role and access
   records. Do not use the same person in both roles without legal approval.

## What the clean specification may contain

- macOS and Swift/Apple API documentation, plus independently written product
  requirements and UI acceptance criteria.
- Device behavior observed in this project's own Android HCI captures, packet
  transcripts, and direct hardware tests. Preserve raw captures and notes;
  never call an inference canonical without the supporting evidence.
- Black-box tests against released behavior expressed as inputs and observable
  outputs, not source-derived algorithms, identifiers, structure, or text.
- Third-party components only with separately verified licenses and their
  original notices.

It may not contain copied code, comments, names that are distinctive rather
than necessary protocol terms, source-shaped pseudocode, decompiled upstream
logic, screenshots/assets without rights, or a mapping from old file/function
to new file/function.

## Reimplementation sequence

1. Establish a new bundle identifier, name, signing/update keys, release
   channel, and repository. Define a migration plan for user preferences and
   device selection without reusing inherited implementation code.
2. Implement a small vertical slice from the clean specification: launch,
   explicit Bluetooth device selection, a read-only safe protocol operation,
   and a menu-bar UI. Maintain the hard opcode block in the new specification.
3. Add independently specified capabilities one at a time. For every protocol
   write, retain the capture/test evidence and obtain direct user hardware
   confirmation before claiming it works.
4. Recreate media, updater, and distribution functions from public APIs and
   clean requirements. Use new source files, tests, UI copy, and visual assets;
   do not mechanically port or "rewrite" old files.
5. Run an independent similarity/provenance review before release: file and
   symbol comparison, asset/font/license inventory, dependency SBOM, and a
   human review by someone permitted to inspect both sides. Counsel decides
   whether the record supports distribution.

## Evidence and release record

For each clean-room release, retain the approved specification revision,
implementer attestations, reviewer findings, test/HCI evidence, dependency
licenses, and build provenance. Publish only claims counsel approves: e.g.
"independently implemented" should describe the documented process, never
assert ownership of third-party protocol, upstream code, names, or assets.

## Exit criteria

No inherited source, generated output from it, copied assets, or upstream-only
dependencies remain in the release tree; every remaining component has a
documented provenance and license; the independent review and counsel sign-off
are complete; and the new release/update channel has been tested from a fresh
install. Until then, this remains planning rather than a clean-room claim.
