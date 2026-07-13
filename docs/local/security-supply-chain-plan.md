# Supply-chain security hardening plan (fork-local, deferred)

## Status and decision

**Reviewed 2026-07-11; implementation deliberately deferred.** This document
preserves the findings and the agreed hardening sequence so that release work
can resume without redoing the discovery. It describes the active fork's
`personal` release channel; when the planned branch transition happens, apply
the same controls to the new working `main` branch before it becomes the
release source.

No evidence of a current compromise was found. This is a risk-reduction plan,
not an incident report.

## What is already good

- The shipped app uses a pinned SwiftPM revision of Sparkle (`2.9.4`, exact
  revision recorded in `Package.resolved`). That prevents a later moved version
  tag from silently changing the resolved source.
- The updater is intentionally branch-bound: a Personal build carries its own
  repository, channel, HTTPS feed URL, and Sparkle public key. It accepts only
  that channel and verifies Sparkle's signed feed/update archive before
  installation. A GitHub release-asset edit alone cannot update installed apps
  without the Sparkle private key.
- zstd is vendored as source in `tools/vendor/zstd-1.5.7`, rather than fetched
  during the app build; its contents are therefore reviewable in the commit
  being built.
- The repository is public, has one direct collaborator (`psiberfunk`, admin),
  and has GitHub secret scanning plus push protection enabled.
- The repository default Actions token is read-only. This is a sound baseline,
  although the current release workflow overrides it (see below).

## Confirmed live GitHub posture (2026-07-11)

Observed through an authenticated read-only GitHub API review. Do not assume
these remain true after this date; re-check before implementing the plan.

| Control | Finding | Consequence |
|---|---|---|
| Repository | Public fork; default branch is `main`; active release branch is `personal`. | Both branches matter: protect `personal` now and `main` before the future transition. |
| Branch protection | Neither `main` nor `personal` is protected; no repository rulesets exist. | A writer can directly alter release inputs. |
| Collaborators | Only `psiberfunk` is a direct collaborator and admin. | Low collaborator exposure, but this one GitHub account is the effective root of trust. |
| Actions policy | All actions/workflows are allowed; full-SHA pinning is not required. | Current `@v4`/`@v5`/`@v6` action tags are mutable supply-chain inputs. |
| Workflow tokens | Repository default is `contents: read`, but `personal-release.yml` declares top-level `contents: write`. | Test and build jobs receive more authority than they need. |
| Sparkle signing key | `DIVOOM_SPARKLE_PRIVATE_KEY` exists as a repository secret; no Environment exists. | A push that changes the workflow can arrange for CI to disclose or misuse the signing key. |
| Dependency alerts | Dependabot alerts/security updates are disabled. | No current automated vulnerability visibility; this does **not** mean there are no vulnerable dependencies. |
| Code scanning | No analysis exists. | Swift, C/C++, Python, and workflow code receive no automated security analysis. |
| Artifact retention | Repository maximum is 90 days; current workflow explicitly uses shorter retention for its artifacts/logs. | Reasonable; not a primary release-integrity risk. |

## Dependency and build-input exposure

Pinning is necessary but not sufficient. It prevents a future upstream change
from silently changing a dependency selection; it does not prove that a chosen
release was safe, that an archive came from its claimed source, or that a
compromised project writer cannot alter the pins.

| Input | Current state | Risk and required direction |
|---|---|---|
| Sparkle | Exact package version and Git revision in `Package.resolved`. | Good drift protection. Continue reviewing every resolution change, record it in an inventory, and monitor security advisories. A pinned revision can still contain a vulnerability or prior compromise. |
| FFmpeg | `8.1.2` download uses HTTPS and a fixed filename, but no expected digest or release-signature verification. | Highest external-source gap. Pin the official source SHA-256 in the script and reject mismatches before extraction; later also verify a release signature with a pinned trusted-key fingerprint. |
| FFmpeg compiled cache | Cached executable/source archive is accepted after self-reported manifest/version checks. | A cache is a speed optimization, not cryptographic provenance. Do not call it a security validation. Prefer a source-only cache for protected releases, or explicitly accept the speed/assurance tradeoff. |
| NASM | Intel CI runs `brew install nasm`. | Mutable Homebrew formula/bottle input. Remove the dependency with `--disable-x86asm` if performance is acceptable, or build a pinned NASM source archive whose digest is verified. |
| dmgbuild / Python release tooling | `dmgbuild==1.6.7` is top-level pinned, but dependencies are not lockfile/hash verified. | Generate a complete, reviewed hash-locked requirements file and install with `pip --require-hashes`. |
| Python dev tools | `requirements-app.txt` packages are unpinned. They are not shipped in the current native app. | Still a local developer/tooling supply-chain exposure; pin/lock them when those tools are actively maintained. |
| zstd | Vendored source, version 1.5.7. | No fetch during build, but document upstream URL, commit/archive checksum, license, and update procedure; monitor CVEs. |
| GitHub Actions | Five GitHub-owned Actions referenced by mutable version tags. | Convert each to a reviewed full commit SHA (keep readable version in a comment), then enable repository enforcement. |
| macOS runner / Xcode | Hosted `macos-15` and `macos-15-intel` labels are mutable hosted build environments. | Record runner image/Xcode/compiler versions in a release manifest. This is an accepted hosted-CI trust dependency unless moving to controlled runners. |

## Primary threat model

1. An attacker gains write access to the source repository or the sole admin
   GitHub account, edits the workflow/build inputs, and publishes a malicious
   update signed with the Sparkle key.
2. A third-party dependency, GitHub Action, FFmpeg archive, package registry,
   Homebrew formula, or CI runner is compromised.
3. A legitimate dependency version later receives a vulnerability disclosure.
4. A release artifact is swapped or a stale update feed is served.

The current Sparkle signature protects installed users from #4 when the
private key remains secret. It does not protect against #1, because current
pushes can reach the job that uses that key.

## Phased hardening plan

### Phase 1 — separate automatic builds from trusted publishing (highest priority)

Keep automatic build/test feedback on every push. Split signing/publishing
into a separate release-promotion job or workflow:

- CI/test/build jobs: `contents: read`, no publishing credentials, no Sparkle
  private key. They can create short-lived internal artifacts.
- Release job: only this job gets `contents: write`, publishes
  `main-latest`/immutable update releases, and generates the signed
  appcast.
- Create a GitHub Environment named `release`; move
  `DIVOOM_SPARKLE_PRIVATE_KEY` from repository-secret scope to that
  environment. Restrict it to the active release branch/tag and require an
  explicit approval before the job starts.
- Promote one reviewed immutable commit (or a reviewed, signed tag), rather
  than treating every `personal` push as an immediately trusted updater
  release.
- Preserve the current updater's branch lock, Sparkle signature requirement,
  user-visible install choice, and no-silent-quarantine-removal behavior.

GitHub Environment approval helps prevent mistakes and prevents ordinary CI
jobs from reading environment secrets. With one administrator it is **not** a
complete defense against compromise of that administrator: an attacker with
full account control may change repository settings. For meaningful separation,
use a second hardware-2FA-protected reviewer identity or retain the Sparkle key
only on a separate local release-signing machine and manually sign/promote a
verified CI artifact.

### Phase 2 — repository and Actions controls

- Protect `personal` immediately; protect `main` before making it active.
- Require pull requests, passing CI, no force pushes, no branch deletion, and
  review for release-sensitive paths (`.github/**`, build scripts, dependency
  manifests/locks, updater code, and release docs). Add `CODEOWNERS` if there
  is a viable independent reviewer.
- Require signed commits where the maintainer workflow can support it.
- Use passkeys/hardware-backed 2FA for maintainers; audit collaborators,
  deploy keys, OAuth Apps, and personal access tokens regularly.
- Convert all Actions to full commit SHA pins, then enable the GitHub setting
  requiring full-SHA pins and restrict allowed Actions to GitHub-owned or an
  explicit allowlist.
- Keep default `GITHUB_TOKEN` permission read-only; grant write and
  attestation permissions only to the protected release job.
- Never add `pull_request_target` or let untrusted pull-request data feed shell
  commands in a privileged workflow.

### Phase 3 — verifiable dependencies and caches

- Add FFmpeg source SHA-256 verification now; add verified release-signature
  checking later.
- Remove or make NASM reproducible as described above.
- Replace the release Python requirements with a complete hash-locked file.
- Keep `Package.resolved` committed; verify Sparkle's release/revision from its
  official project before accepting an update.
- Add a `DEPENDENCIES.md` inventory covering Sparkle, FFmpeg, zstd, Python
  tooling, Actions, licenses, source locations, exact revisions/digests, and
  update owner/procedure.
- For the strongest release posture, cache only digest-verified FFmpeg source
  and rebuild its binary in the protected release job. If binary caching is
  retained, include source digest, recipe digest, architecture, Xcode, and
  compiler version in the cache key/manifest, and document the residual trust
  risk.

### Phase 4 — detection, provenance, and release evidence

- Enable Dependabot alerts, security updates, and version updates for Actions
  and supported package ecosystems. Review updates; do not auto-merge them.
- Enable CodeQL for Swift, C/C++, Python, and GitHub Actions workflows.
- Add Actions-specific lint/security checks (for example, actionlint plus a
  workflow-security linter) in the unprivileged CI path.
- Generate a release SBOM and a human-readable build manifest including commit,
  dependency revisions/digests, runner image, Xcode/compiler version, and
  FFmpeg verification result.
- Generate GitHub artifact attestations for the user DMG, immutable update ZIP,
  FFmpeg source archive, and SBOM; verify them in the release checklist.
- Periodically build the same reviewed commit twice and compare the meaningful
  binary/component hashes. DMG/container timestamps may prevent whole-DMG
  byte-for-byte equality, so document what is expected to differ.

### Phase 5 — incident readiness and Apple distribution hardening

- Write `SECURITY.md` with a private reporting route, supported channels, and
  disclosure expectations.
- Document emergency steps: freeze releases, revoke repository/environment
  access, rotate the Sparkle key, audit release assets/logs, and notify users.
- Design a Sparkle key-rotation/recovery path before wide distribution. A
  single embedded public key makes post-compromise recovery difficult; do not
  assume key rotation can be improvised after an incident.
- When available, adopt Developer ID signing and notarization for the app/DMG.
  This protects the initial-install trust experience separately from Sparkle's
  subsequent-update protection, and lets the temporary Gatekeeper bridge be
  removed.

## Implementation order when unshelved

1. Phase 1 release boundary and Phase 2 minimum controls.
2. Full-SHA Action pins, FFmpeg digest verification, and per-job permissions.
3. Locked Python release dependencies, NASM decision, and dependency inventory.
4. Dependabot, CodeQL, workflow linting, SBOM, attestations, and release
   checklist.
5. Key-rotation design and Developer ID/notarization.

## Acceptance checks

- An ordinary CI job cannot read the Sparkle private key or create/edit a
  release.
- A release job cannot start or access its environment secret before review.
- All workflow Actions are immutable full-SHA references and repository policy
  rejects mutable action tags.
- A modified FFmpeg archive fails before extraction; a legitimate archive
  succeeds.
- Dependency update PRs are visible and reviewed; no alert scanner is merely
  assumed to be active.
- A published release has a verified appcast signature, SBOM, provenance
  attestation, and recorded source/build inputs.
- A test update from the preceding public build still reaches the current
  branch-locked release only after Sparkle verification.

## References consulted during this review

- GitHub Actions secure-use guidance (least privilege and immutable action
  pins): <https://docs.github.com/en/actions/reference/security/secure-use>
- GitHub deployment environments (approval-gated environment secrets):
  <https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments>
- GitHub Dependabot Action updates:
  <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/auto-update-actions>
- GitHub artifact attestations:
  <https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations>
- GitHub CodeQL language support:
  <https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-code-scanning>
