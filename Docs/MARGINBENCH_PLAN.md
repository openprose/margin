# MarginBench build plan

Last updated: 2026-08-18 02:27 ET

MarginBench is the working name for a portable, execution-scored benchmark for
human-to-agent and agent-to-agent collaboration over Markdown workspaces. The
benchmark core belongs to Margin, not to any model provider. Prime Intellect is
the first hosted adapter, evaluation venue, and possible training backend.

This document is the live checklist for the build phase ending at 08:00 ET on
2026-08-18. Update the status and evidence here as each gate is crossed.

## Non-negotiable constraints

- Margin's CLI must remain fast, local-first, deterministic, and usable without
  a network connection.
- The macOS app must not pay a startup cost for benchmark or provider code.
- Agents receive only the collaboration surface intended by a scenario. The
  scorer and hidden answer data remain outside their runtime.
- Correctness and safety are measured by executable checks, not by an LLM judge.
- Public results must disclose the model, harness, role layout, Margin build,
  task-set version, limits, retries, latency, token use, and cost.
- Paid experiments proceed from cheap probes to paired pilots. A failed setup is
  fixed locally before another paid run.

## Credit ledger and spending gates

Opening Prime Intellect credit: **$199.9861**. Latest observed balance:
**$199.9594**. Total debit so far: **$0.0267**.

| Gate | Maximum cumulative spend | Purpose | Status |
| --- | ---: | --- | --- |
| 0 | $0 | Install, login, local tests, container builds, dry runs | Complete |
| 1 | $2 | One tiny end-to-end hosted smoke test | Complete; $0.0017 first valid smoke |
| 2 | $15 | Cheap-model calibration on a small public-development slice | Complete; cumulative debit $0.0267 |
| 3 | $50 | Paired comparisons of promising CLI/manual variants | Not started |
| 4 | $120 | Broader model/team matrix only after stable signal | Not started |
| Reserve | $80 | Held for follow-up, failures, and a meaningful final run | Untouched |

Rules:

1. No paid run before all local oracles pass and the exact proposed run is
   emitted by a no-model preflight.
2. Every paid command has hard process, turn, response-token, and timeout caps,
   plus a conservative pre-run dollar admission gate. Prime does not provide a
   live per-run wallet cutoff, so the distinction is explicit.
3. A new phase runs only if the previous phase produced useful signal.
4. Never spend the final $80 during this build phase without a written proposal
   explaining the expected information gained and estimated full-run cost.
5. Keys, raw prompts, hidden seeds, credentials, and unredacted traces are never
   committed.

## Work plan

### 1. Record and secure the starting point

- [x] Create this tracked plan and budget ledger.
- [x] Confirm the repository starts clean at commit `9e1b95c`.
- [x] Confirm the supplied screenshot shows an active Prime API key expiring
  2026-11-04; do not create or expose another key unless authentication fails.
- [x] Install the official Prime CLI and verify account access without spending
  credits.
- [x] Record exact local tool versions and a redacted authentication check.

### 2. Make the Margin engine portable

- [x] Separate the AppKit application product from the platform-neutral core and
  CLI products in the package manifest.
- [x] Replace Darwin-only imports and file primitives with audited Darwin/Linux
  implementations behind a small compatibility layer.
- [x] Preserve locks, atomic replacement, permissions, crash recovery, and
  embedded-comment behavior on both platforms.
- [x] Build and run the core/CLI tests in a Linux container.
- [x] Re-run all macOS tests, package checks, and startup measurements; reject a
  material regression.

### 3. Build the provider-independent benchmark core

- [x] Define versioned task, role, event, tool-policy, trace, candidate, binary,
  and run schemas.
- [x] Generate deterministic, secret-seeded Markdown workspace episodes.
- [x] Support sequential roles, concurrent roles, scripted human events,
  external edits, stale state, interruption, and retry.
- [x] Place a strict Margin gateway between agents and the shared workspace.
- [x] Score exact outcomes, source preservation, all-or-none transactions,
  attribution, recovery, calls, tokens, latency, human attention, and cost.
- [ ] Add single-agent, no-collaboration, and unconstrained-shell controls.
- [x] Add reference, idle, spam, fake-agent, and adversarial tests with no paid
  model calls. The remaining control variants are benchmark breadth, not a
  correctness blocker.
  The control catalog and fail-closed execution gates are now frozen; only the
  primary Margin-only profile is marked runnable until the other three meet
  their identity, task-neutral scoring, and remote-isolation requirements.

### 4. Add the Prime Verifiers adapter

- [x] Package a Verifiers v1 environment with named role agents and one shared
  per-episode Margin workspace/gateway.
- [x] Keep the benchmark's task generator and scorer provider-independent.
- [x] Support local Docker execution and verify the same pinned Linux binary in
  a Prime-managed sandbox without invoking a model.
- [ ] Run the complete hosted role environment after it can be published under
  an Environment Hub owner handle.
- [x] Verify concurrent roles cannot access hidden fixtures, credentials,
  scorer state, ambient tools, or one another's private briefs.
- [x] Produce a Hub-ready wheel/source package and reproducible setup
  instructions. Private Hub publication is blocked only because the selected
  OpenProse team has no registry handle configured; packaging and local Prime
  execution do not depend on that setting.

### 5. Establish the hill-climbing loop

- [x] Freeze Margin binary/manual/settings bundles by digest.
- [x] Express CLI/manual/default changes as named candidates.
- [x] Compare candidates on identical seeded episodes with paired ordering and
  repeated trials.
- [x] Require safety/integrity parity and statistically meaningful improvement
  before promotion.
- [x] Keep prompt optimization, CLI optimization, model comparison, and team
  orchestration as separate benchmark tracks.
- [x] Store redacted run summaries and a machine-readable experiment ledger.

### 6. De-risk with staged Prime runs

- [x] Run no-cost install/auth/runtime/model discovery.
- [x] Run one cheapest useful hosted smoke test (Gate 1).
- [x] Run a small cheap-model calibration only if the smoke is valid (Gate 2).
- [x] Hill-climb at least one bounded CLI/manual candidate pair after
  calibration exposed concrete failures.
- [x] Stop on infrastructure ambiguity, vacuous scoring, or safety leakage and
  repair locally before spending again.

### 7. Publishable benchmark foundation

- [x] Use the distinct working name **MarginBench**; avoid the existing
  “CollabBench” name collision.
- [x] Document public development tasks versus private, rotating test tasks.
- [x] Define four result tracks: model, interface, team, and open systems.
- [x] Add explicit code/data licensing recommendations and contamination policy.
- [x] Draft a benchmark card covering scope, limits, metrics, reproducibility,
  security, and leaderboard submission rules.

## Acceptance gates for 08:00 ET

The phase is successful if the repository contains:

1. This current, evidence-backed progress ledger.
2. A Linux-capable Margin core/CLI with Linux and macOS verification, or a
   precisely isolated remaining portability blocker with tests around it.
3. A provider-independent MarginBench core with deterministic local scenarios.
4. A working Prime Verifiers adapter that passes local/no-model preflight.
5. At least one valid, capped Prime smoke result if account/runtime access works.
6. Exact spend, latency, model, harness, score, and safety records for every paid
   attempt, including invalid attempts rather than hiding them.
7. A clear proposal for the next statistically useful run and its estimated
   cost, without consuming the reserve by default.

## Evidence log

- 2026-08-17 21:25 ET — Started from clean `main` at `9e1b95c`.
- 2026-08-17 21:25 ET — `uv 0.7.8` is available; Prime Agent is installed;
  the separate Prime Environments CLI is not yet installed.
- 2026-08-17 21:25 ET — Screenshot review found one active API key. No secret
  value was requested, copied, printed, or stored.
- 2026-08-17 21:30 ET — Installed Prime CLI 0.6.24 (including Verifiers 0.3.0)
  and downloaded the official Swift 5.10 Jammy container image.
- 2026-08-17 21:31 ET — Browser challenge authentication succeeded. Selected
  the OpenProse team context; authenticated Environment Hub access works and the
  read-only wallet balance was $199.9861. No paid job was launched.
- 2026-08-17 21:41 ET — MarginCore and `margin-cli` compile in the clean Linux
  container. Portable SHA-256, POSIX file operations, Linux watch behavior, and
  Linux transaction mode preservation are under full-suite verification.
- 2026-08-17 22:00 ET — The reproducible Linux gate passed all 112 portable
  core/CLI tests in Swift 5.10 Jammy. Tests run as isolated XCTest processes in
  one disposable container after a single build, avoiding a known SwiftPM 5.10
  repeated-planning stall without masking per-suite timeouts.
- 2026-08-17 22:00 ET — The complete macOS suite passed 164/164, and the signed
  release smoke test passed bundle, CLI, document-inspection, and visible-window
  launch checks.
- 2026-08-17 22:01 ET — Warm macOS launch measurement improved to 304.169 ms
  median / 341.175 ms p95, with 159.219 MiB median / 159.641 MiB p95 RSS. This
  is better than the pre-port candidate's 331.928 ms median and 161.875 MiB
  median RSS; no startup or memory regression was introduced.
- 2026-08-17 23:00 ET — The provider-independent core reached five deterministic
  scenario families, eight public schemas, exact topology/type/provenance
  scoring, strict workspace confinement, reproducible candidate digests, and a
  100/100 no-model reference matrix on macOS and Linux x86-64/arm64.
- 2026-08-17 23:30 ET — Built a manylinux x86-64 wheel and source archive with
  the pinned Margin binary and self-tests. A private Environment Hub push
  reached registry validation but stopped before upload because the OpenProse
  team has no team handle; no secret or paid inference was involved.
- 2026-08-17 23:58 ET — Expanded the local Prime Verifiers rehearsal to every
  role in all five scenarios. All five episodes scored 100 with one exposed
  `margin` tool and no paid model calls. The rehearsal also caught and fixed a
  provider portability edge where JSON-looking standard input arrives as a
  structured object.
- 2026-08-18 00:00 ET — Cheap Qwen Flash development runs exposed successive
  interface failures: missing read aliases, reply-versus-root confusion,
  omitted resolution, distracting source-offset work, and pseudo-action labels
  that resembled commands. Exact command paths and argument shapes in bounded
  context lifted the human-relay outcome to the correct durable state; an old
  scorer requirement recorded 96.25 although the post-run oracle now recognizes
  the equivalent bounded read and scores that state at 100.
- 2026-08-18 00:05 ET — The first handoff attempt scored 66.25 because a
  1,200-token response ceiling ended the author before its first tool call. A
  fair 2,400-token per-call window plus optional `--json` on always-JSON reads
  produced 100/100, zero invalid commands, and correct author/reviewer work for
  $0.0028. Total Prime debit since the opening balance is $0.0139.
- 2026-08-18 00:28 ET — Gate 2 now covers all five collaboration families with
  real Qwen Flash agents. The strongest current candidates reached the exact
  required state in human relay, handoff, concurrent review, suggestion
  decision, and stale multi-file recovery. Recorded scores were 100, 100,
  92.083, 89.821, and 92.5 respectively; the sub-100 scores expose avoidable
  commands and syntax errors rather than lost document state. Cumulative debit
  is $0.0267, leaving $199.9594.
- 2026-08-18 00:35 ET — Audit found that the first paid wrapper called
  Verifiers' soft, deduplicated graph-token limit a billing maximum. The staged
  run made the error visible: its recorded $0.0044 exceeded the old $0.00396
  estimate. Further paid calls stopped immediately. The wrapper now requires a
  provider/model input ceiling per call, multiplies it across every allowed
  turn and SDK retry attempt, and includes a billing-rounding allowance. A dry
  test refuses the old $0.01 cap and admits only a plan whose stated bound fits.
  Earlier result files remain unchanged historical records; their estimate
  field is nominal, not a valid upper bound.
- 2026-08-18 00:51 ET — A separately gated, no-model Prime runtime probe
  uploaded the rebuilt x86-64 Linux binary to a minimal managed sandbox, ran a
  real typed comment write, and validated the resulting Markdown. It completed
  in 39.302 seconds on a cached image, deleted the sandbox, left zero active
  sandboxes, and produced no visible wallet debit. The plan estimated $0.000203
  for two minutes and admitted only against a $0.1464 worst-case 24-hour cleanup
  bound. The redacted result is tracked and schema-validated.
- 2026-08-18 01:15 ET — Margin 0.3.2 passed the complete macOS package suite:
  164 tests, zero failures. The final agent-facing mutation responses include
  exact read-only verification commands for typed work, suggestions, and
  handoffs; this directly addresses the remaining avoidable syntax failures in
  the cheap calibration traces without adding startup work.
- 2026-08-18 01:20 ET — The frozen 0.3.2 source passed all 112 portable tests in
  Swift 5.10 Jammy. Fresh x86-64 and arm64 Linux binaries both report 0.3.2 and
  score 100 on all five reference episodes. Rebuilding x86-64 from the same
  source produced the identical SHA-256
  `ba5daecb6d7fb1874a9726313cf2c871ad37691dba1cf59bb655642f03314919`.
- 2026-08-18 01:21 ET — MarginBench now has 12 public schemas, a deterministic
  20-pair counterbalanced study planner, a fail-closed control catalog, safe
  private holdout-key creation, benchmark-implementation provenance, bounded
  candidate promotion tests, a complete 13-attempt experiment ledger, and a
  corrected worst-case paid-run admission calculation. The 25 benchmark tests
  pass under both the system and Prime runtimes; Prime's five-workflow fake-model
  rehearsal scored 100 throughout with one exposed `margin` tool and no paid
  calls.
- 2026-08-18 01:23 ET — The final manylinux wheel and source archive passed
  their tests inside clean Linux containers. Their SHA-256 values are
  `4907f4e21b052a42f0dd0d4528604c2e90d2d7bd67713fbd3b7134b1dd520cd6`
  and `074f75f5e45d41a0830f37092939b10c4ee7455919c7567b0a0d80cd0c271071`.
  Packaging now removes obsolete MarginBench artifacts from the release folder
  so an older pure-Python wheel cannot be shipped beside the Linux build.
- 2026-08-18 01:23 ET — The signed-for-local-use Mac app passed its live smoke
  test and was packaged together with the CLI as both a zip and installer.
  Warm launch measured 308.819 ms median / 345.535 ms p95, with 158.078 MiB
  median RSS. This remains within ordinary run-to-run variance of the 304.169 ms
  post-port baseline and keeps all benchmark/provider code off the launch path.
- 2026-08-18 01:55 ET — Added an offline, 16 MiB-bounded publication validator
  with 16 bundled schemas, duplicate-key/non-finite-number rejection, and
  semantic checks for identities, event and role counts, cost reconciliation,
  counterbalancing, candidate digests, and promotion claims. It checks all 17
  tracked JSON evidence files and explicitly reports the four known historical
  defects rather than rewriting them. The system runtime passes 29 tests with
  four Prime-only skips, while Prime's runtime passes all 33; the five-workflow
  reference and fake-model matrices remain perfect with no paid call. The
  candidate comparator now rejects unvalidated or tampered result inputs and
  preserves privacy-minimized command events instead of discarding them. A
  source-checkout runtime test also resolves its package path before changing
  directories, eliminating a reproducible 30-second MCP startup timeout when a
  caller supplied a relative `PYTHONPATH`. The frozen benchmark implementation
  digest is
  `b393cb4fd2cc1d8097a2f928e7076ceffd4291d86d69cbfb3125f45f4c3b6fb2`.
  The repackaged, clean-container
  verified wheel is
  `4accb41d0579039e80d6c57fd93f5c14c460390d36f2903e878ca3e97323238b`;
  the source archive is
  `00b355103f8e840d53486eadfe345c24b152d59e8078b63eb10f3b232fa42af1`.
- 2026-08-18 02:15 ET — Added a least-privilege GitHub Actions gate that
  rebuilds the exact Linux x86-64 binary, runs the 112 Swift tests and both
  Python/Prime suites, performs the five-scenario no-model rehearsal, exercises
  the wheel in pinned Linux, and retains only the package plus a validation
  receipt. It uses no credential or paid model. `actionlint` passes. The package
  verifier itself now uses portable size and zip operations, and its complete
  macOS-hosted clean-Linux check still produces the exact recorded hashes. The
  workflow's first hosted run awaits a repository remote; all underlying steps
  have already passed locally or in the same pinned containers.
- 2026-08-18 02:27 ET — Added a deterministic, cross-artifact submission
  manifest and offline verifier for leaderboard evidence. It binds both
  candidates, the study plan, every redacted run, and the comparison by digest;
  requires exact paired coverage; verifies benchmark, track, control, case, and
  build identity plus track-specific fixed execution settings; prevents a
  post-hoc promotion-threshold reduction; and recomputes the comparison from
  per-episode measurements.
  Artifact reads are single-snapshot, 16 MiB each and 64 MiB aggregate; raw
  traces, prompts, fixtures, credentials, and holdout keys are excluded. The
  candidate promotion gate now also rejects source corruption independently of
  the baseline. The system runtime passes 30 tests with four Prime-only skips,
  Prime passes all 34, and the five-workflow reference and fake-model matrices
  remain 100 without a paid call. The frozen implementation digest is
  `6b254d4874687f9b691ae310fc11068e7319a6aa07f625b23a4c4d2266eb8b12`.
  The clean-Linux verified wheel is
  `0b6677be94d6e49c17dc55b303d15e96a3b84dc000c78d3ba64c526614f28d71`;
  the source archive is
  `133084d01f376eafcd4e92823e3dc772ee57eb4a408e57d4999f9056f45c52e8`.

## Next statistically useful paid run

The next useful experiment is not another one-off. It is a paired interface
comparison over all five workflows with four private repetitions: 20 matched
episodes per candidate, 36 role processes per candidate, and exactly balanced
AB/BA ordering. That is the smallest default study eligible for promotion.

At Qwen Flash's current API price of $0.03/M input tokens and $0.13/M output
tokens, a **provisional** 65,536-input-token ceiling, 2,400 output tokens,
12 turns, three possible upstream attempts per turn, and $0.0002 rounding
allowance gives a conservative bound of $3.211592 per candidate or $6.423184
for the pair. This is well inside Gate 3's $50 envelope and far above observed
cost, which is intentional. It is not execution-ready until Prime or the model
publisher documents that 65,536-token per-call ceiling. Prime's current Models
API exposes price but not context length, so substituting an assumed value would
repeat the billing-bound error already caught here. No broader paid run should
start until that contract fact is verified and a no-model plan is reviewed.

## Decisions still to earn with evidence

- Whether the first public release should live inside this repository or in a
  standalone `marginbench` repository once the schemas stabilize.
- Whether the published hosted environment should use one container per role or
  separate agent runtimes connected to the same narrow gateway. Local Prime
  subprocess isolation is working; remote isolation remains the publication
  gate.
- Qwen 3.7 Flash is inexpensive enough for interface calibration and produces
  useful failure diversity. One-role runs have cost about $0.0004-$0.0017;
  the successful two-role handoff cost $0.0028 and the longest staged run cost
  $0.0044.
- At observed prices, the $200 balance is far larger than the development need.
  Broad runs should still wait for stable cases: 100 two-role episodes at the
  observed handoff cost would be roughly $0.28, before retries or model changes.
  This is an empirical planning figure, not an admission bound; future run
  proposals must also report the corrected worst-case calculation.
