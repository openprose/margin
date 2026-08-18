# MarginBench build plan

Last updated: 2026-08-18 07:35 ET

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
**$199.9487**. Total debit so far: **$0.0374**.

| Gate | Maximum cumulative spend | Purpose | Status |
| --- | ---: | --- | --- |
| 0 | $0 | Install, login, local tests, container builds, dry runs | Complete |
| 1 | $2 | One tiny end-to-end hosted smoke test | Complete; $0.0017 first valid smoke |
| 2 | $15 | Cheap-model calibration on a small public-development slice | Complete; cumulative debit $0.0374 |
| 3 | $50 | Paired comparisons of promising CLI/manual variants | Not started |
| 4 | $120 | Broader model/team matrix only after stable signal | Not started |
| Reserve | $80 | Held for follow-up, failures, and a meaningful final run | Untouched |

Rules:

1. No paid run before all local oracles pass and the exact proposed run is
   emitted by a no-model preflight.
2. Every paid command has hard process, turn, response-token, and timeout caps,
   plus a conservative pre-run dollar admission gate. A local, loopback-only
   proxy now also rejects requests after the cumulative reservation cap before
   they reach Prime; it is not a provider-side wallet cutoff.
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
- [x] Add topology-aware dry planning for gated controls: logical roles,
  model-process counts, trace seats, and phase policy are distinct and validated;
  execution remains refused until each profile's complete gates pass.
- [x] Freeze the fairness, identity, cost, isolation, and release contract for
  those controls in `Docs/MARGINBENCH_CONTROLS.md`; none is marked runnable
  before its complete gate lands.
- [x] Add reference, idle, spam, fake-agent, and adversarial tests with no paid
  model calls. The remaining control variants are benchmark breadth, not a
  correctness blocker.
  The control catalog and fail-closed execution gates are now frozen; only the
  primary Margin-only profile is marked runnable until the other four meet
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
- [x] Add a whole-study controller that is dry by default, protects an explicit
  wallet reserve, can pause after one newly completed job, resumes only from a
  verified contiguous receipt prefix, and never retries an uncertain paid
  attempt automatically.

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
- 2026-08-18 02:43 ET — Closed the gap between a counterbalanced study and the
  hosted task selector. A deterministic execution-plan artifact expands the
  default study into 40 digest-identified jobs in exact AB/BA order; Prime can
  now select arbitrary repetition IDs rather than always beginning at zero.
  Frozen candidate manifests are checked against the candidate ID and exact
  executable before a run. Private study planning and hosted generation now use
  identical key bytes, and the taskset consumes the mode-0600 secret from its
  environment before any agent subprocess starts. A real no-model private-plan
  rehearsal selected repetition 7, matched the one-way key ID, and confirmed
  that the secret was absent from output. The system runtime passes 31 tests
  with five Prime-only skips and Prime passes all 36; no paid call was made.
  The frozen benchmark implementation digest is
  `11527727e146e830bee35d6bad0de51d079fbcae5d2da798a1e75133d3fcca94`.
  The clean-Linux verified wheel is
  `7bd7de6b71e57d80dffa84d3cea190a0fe004ec9da82038d3156d1dc5f7af94e`;
  the source archive is
  `3bae868f886143aee060d1e6bcaa7849025ac47961fe3847331a02910b56adb7`.
- 2026-08-18 02:53 ET — Bound the exact execution plan into leaderboard
  submissions; an individually valid but reordered plan now fails deterministic
  cross-artifact verification. Added a zero-model paired reference-study runner
  that executes every scheduled job against both frozen binaries through the
  real gateway, scores the results, creates redacted run manifests and a paired
  comparison, assembles the complete publication directory, and re-verifies it
  before atomically exposing the output. Its direct and command-line regressions
  produce a valid seven-artifact submission with two 100-point candidate runs,
  one tie, no raw trace directory, and `paidModelsInvoked:false`. The system
  runtime passes 32 tests with five Prime-only skips; Prime passes all 37. The
  frozen benchmark implementation digest is
  `86644158a64d5af9b141569bbb0f1780e26be68dcd5111b0735e3aea5233911b`.
  The clean-Linux verified wheel is
  `8d5b5676d271d6d4929bca8fb6ea7e8c2a9c2a057952fcab190282b4433a81a4`;
  the source archive is
  `ad6aacbf35d370a59a29c94c4c7a7f0d7973187590dfa6a0ff09e54872902445`.
- 2026-08-18 03:15 ET — Added the paired Prime study controller without making
  another model call. Its immutable public plan binds both candidate manifests
  and executables, the exact job schedule, generation-key ID, model, all live
  limits, provider prices, per-job worst cases, whole-study cap, and minimum
  wallet reserve. The executor holds one controller lock, checks the wallet
  against the remaining worst case before each job, writes an attempt marker
  before starting inference, validates matching redacted summary/run bytes
  before writing a resumable receipt, refuses noncontiguous state, and performs
  no automatic paid retry. A fake-child integration stopped after one job,
  resumed at job two, produced a verified submission, and then replayed without
  reading the wallet or launching a child. An uncertain unreceipted attempt
  blocked the second invocation before wallet or process access. A complete
  private dry plan contains 40 jobs and 72 role processes, omits the key value,
  preserves an $80 reserve, and computes a $6.423192 worst case from the
  provisional 65,536-token assumption. Candidate inputs and the private key are
  copied into the mode-0700 ignored work area and digest-checked before any paid
  call, so later jobs and publication cannot drift with the original paths. The
  system runtime passes 35 tests with five Prime-only skips; Prime passes all 40. No
  balance change or model call was made. The frozen benchmark implementation
  digest is
  `c0be396d17869a96035389d7e782f0f37132b4d86d185df36217792fa12d1af2`.
  The clean-Linux verified wheel is
  `609ce9ffa6aa300c41c9ee687c59f55472fe021b1e327b4e5a4e18494addb632`;
  the source archive is
  `d078228427b5afa4856240d09bbd865edd0ee6c81c15eec1a428106bd5f1f5ab`.
- 2026-08-18 03:34 ET — Hardened the paid worker's final evidence boundary.
  Before claiming a paid start it now rejects an existing output directory,
  summary, run manifest, duplicate output names, or dangling symbolic-link
  target. Redacted summary and run records are schema-checked, written with
  private permissions, flushed, and atomically linked into place without ever
  replacing prior evidence. A collision regression proves the original bytes
  survive. The ordinary runtime passes 36 tests with five intentional
  Prime-only skips, and Prime's pinned runtime passes all 41. No model or paid
  service was invoked.
- 2026-08-18 03:45 ET — Added a sixth scenario for directory-scale continuity:
  one agent triages and resolves a human architecture thread in one file,
  leaves a typed handoff in another, and a second isolated agent discovers,
  replies to, and resolves it from bounded root context. The exact reference
  takes 13 valid commands across three Markdown files and scores 100. The full
  four-repetition default now contains 24 paired episodes, 48 ordered candidate
  jobs, and 88 role processes; its complete no-model run gave both candidates a
  100 minimum, 24 ties, and a verified seven-artifact publication bundle. The
  Prime fake-agent rehearsal produced six 100 rewards in 59 turns through one
  Margin tool. The system suite passes 36 tests with five Prime-only skips and
  Prime passes all 41. Fresh x86-64 wheel and Linux arm64 self-tests both pass
  all six cases; the clean Linux source package passes 41 tests with 18 expected
  optional/runtime skips. No paid call was made. The implementation digest is
  `2170e28eea718e72e9b6481f11776b1de8e09a6179d7a892124ad65437f30ff9`.
  The Linux-verified wheel is
  `4762696f8c281a921ddf6a424d307a27668ab24ae14b7f4ee0db69c807e1836e`;
  the source archive is
  `3a5c69dea0a756594bd110fbed3802b5344e71036a8742c9137b2ce95db0870a`.
- 2026-08-18 03:52 ET — Closed the hosted Prime task reconstruction gap. The
  client wire now remains limited to public selection fields and a one-way case
  fingerprint. Prime's actual environment server can rebuild a task without a
  hidden Python attribute; the trusted environment regenerates the episode from
  its key, checks the fingerprint and control profile, and fails closed on
  tampering before starting an agent. Role tasks are plain public tasks with no
  fixture or oracle attribute. Prime passes all 42 contracts, including a real
  server reconstruction regression; the ordinary runtime passes 36 with six
  intentional Prime-only skips. The six-case fake-agent matrix remains 100.
  A fresh Linux package passes its six-case wheel self-test and 42 source tests
  with 19 expected optional/runtime skips. No paid call was made. The
  implementation digest is
  `3be5f580ef040b0e1edefb97cb1f57f78f7c8fa9c61e47f51c7a16e9e28bb042`.
  The Linux-verified wheel is
  `78148f4969b463a9dbaed944d0bd80e13c219f7588acb2281b2ba9bb7baaac72`;
  the source archive is
  `a1955f881a07485e8a9cca1c6ba586ea2527633ddfe78ed98351831e5928b445`.
- 2026-08-18 04:08 ET — Exercised the entire six-case fake-model matrix through
  Prime's real out-of-process environment server, not just the in-process
  adapter. A private-key rehearsal first exposed that Prime materializes public
  task selections before its trusted worker is spawned. The lifecycle now keeps
  the key only long enough for that worker to inherit it, regenerates and checks
  the hidden episode there, and removes the key before Margin resolution,
  workspace or gateway creation, or any agent process. Both private in-process
  and private served rehearsals scored six of six at 100; output contained only
  a one-way key ID, and each temporary key was overwritten and deleted. Public
  preflight also strips an ambient key unless its mode-0600 file is explicitly
  named. Make and CI now require both public execution modes; CI additionally
  creates, tests, overwrites, and deletes a fresh private key. `actionlint`,
  Ruff, and diff checks pass. The system runtime passes 37 contracts with six
  intentional Prime-only skips; Prime passes all 43. A fresh Linux source
  package passes 43 tests with 19 expected optional/runtime skips, and its wheel
  again scores all six reference cases at 100. No paid model was called. The
  implementation digest is
  `861e29f8f86ac7fe29dae9693cec68a8654dae0bce283a7002ad5e92b7771b4e`.
  The Linux-verified wheel is
  `d72be45bd1bb51b51d83ee07c2dc34f864fc602eb6ab8cb7b04294ee5b6bc133`;
  the source archive is
  `fa2addb0d5f0197043c314e53e39cdbf8881d79748aeec89decdfb07bb851aa8`.
- 2026-08-18 04:23 ET — Added the deterministic feedback step needed to turn
  benchmark evidence into disciplined interface experiments. `marginbench
  diagnose` accepts validated results and redacted run summaries, reads each
  once within the 16 MiB bound, and ranks safety/integrity, missing durable work,
  stale recovery, command discoverability, attribution, interaction count, and
  exhausted agent budgets. It reports bounded candidate/scenario breakdowns and
  holds model, cases, roles, and limits constant while recommending one surface
  change. Any safety failure blocks paid expansion; an ordinary candidate is
  directed to at least 20 matched private cases. The report retains no document
  text, prompt, raw trace, key, or local artifact path and is itself the 25th
  schema-checked public format. A historical multi-candidate rehearsal exposed
  and closed one analysis error: an early unsafe baseline could initially block
  a later safe candidate. Multi-candidate reports now require an explicit focus;
  with the newest staged candidate selected, the same evidence ranks command
  discoverability first and excess interaction second while retaining the full
  candidate history for comparison.
  Completed paired Prime studies now create this report automatically, prove it
  covers exactly the submission's redacted runs, and bind its digest and first
  opportunity into the completion receipt; tampering makes replay fail before
  wallet or model access. The wheel was installed—not merely unpacked—on pinned
  Python 3.13 Linux and completed self-test, diagnosis, and validation; the clean
  source archive passes 44 tests with 20 expected optional/runtime skips. The
  system runtime passes 38 contracts with six Prime-only skips and Prime passes
  all 44. No paid model was called. The implementation digest is
  `17c88ee581730e3231fd680d6ea3b6cb0d86dc1b1d70629a95c5dda755b556e3`.
  The Linux-verified wheel is
  `7fee22a178685ec26bfab2b0e0d1cdbc60bec7100577502af2a4c1e0e48baf41`;
  the source archive is
  `8354f6dbe0cd4e7ed43e45ed58f5e57970002e85e54dbf7ad8c74165fea632cc`.
- 2026-08-18 04:52 ET — Closed the last billing-bound uncertainty and ran the
  first directory-wide human-agent-agent hill climb. Alibaba's current official
  model table documents a 1M-token context for `qwen3.7-flash`, while Prime's
  authenticated Models API reports $0.03/M input and $0.13/M output. The source
  is https://help.aliyun.com/zh/model-studio/text-generation-model/ . Three
  serial, temperature-zero public-development cells held the Qwen model, exact
  generated episode, Margin build, role layout, turn/token limits, and provider
  prices fixed. They cost $0.0026, $0.0032, and $0.0039 respectively—$0.0097
  total against a deliberately pessimistic $1.82136 admission bound per cell.
  The wallet moved from $199.9594 to $199.9497 and no automatic paid retry ran.

  The initial `directory-context-handoff-v1` cell scored 25.0: source and
  documents stayed intact, but the author mistook `--actor-id` for the handoff
  recipient, the reviewer attempted `ls`, then consumed its budget on the full
  69 KB capability catalog. The boundary blocked both unsafe forms. Exact
  blocked-call recovery guidance and a smaller-workflow warning produced
  `directory-handoff-guidance-v2`: 91.944444, exact durable state, correct
  attribution, safe confinement, and one recovered stale revision. A further
  single-read hint produced `single-read-handoff-guidance-v3`: 96.25, zero
  invalid Margin commands, both agents completed, and every durable-state,
  attribution, source, document, atomicity, and confinement check passed. The
  agent still sometimes requested overlapping reads, so the final delta cannot
  be attributed to that one sentence from a single sample; it remains a
  calibration result, not a promotion claim. The direct v1→v3 comparison is
  +71.25 points and -2 invalid commands, with `sampleSizeSufficient:false`.

  This live trace also found an evaluation defect: the role did verify the
  finished threads and bounded directory state, but the oracle required the
  literal `comments validate` spelling. That command-specific requirement is
  removed for future episodes; exact annotations, status, attribution, source
  bytes, valid documents, and the core handoff workflow remain independently
  scored. Recorded paid scores were not rewritten. Diagnostics now distinguish
  actual document damage from a disallowed attempt that enforcement blocked,
  redacted run manifests preserve bounded stop-condition counts, and
  `marginbench compare` accepts redacted paid summaries/manifests directly.
  The validated ledger now contains 16 attempts, 15 completed runs, 187 model
  calls, and $0.0364 total wallet debit since the original $199.9861 opening
  balance. No raw trace, prompt, document body, credential, or holdout key was
  committed.

- 2026-08-18 05:10 ET — Added a live, fail-closed inference spend boundary
  without making another paid call. Every future paid `prime_pilot.py` run now
  keeps the real Prime key in its parent process and gives Verifiers only a
  random loopback capability. The proxy pins the priced model and exact
  non-streaming chat-completion route; bounds encoded request, response, and
  output size; serializes conservative per-request reservations under the run
  cap; never releases a failed reservation; forwards only minimal headers; and
  retains no request or response content. Redacted summaries and run manifests
  carry schema-checked policy, forward/reject counts, reserved cost, and
  provider-reported tokens. Unit tests cover authentication, route/model/output,
  byte, and cumulative-cost rejection. Prime's complete six-scenario fake-model
  rehearsal then passed through the proxy both in process and across its real
  environment-server boundary: 6/6 rewards, 59/59 requests accounted for, zero
  rejects, and `paidModelsInvoked:false`. The newly approved Prime login was
  independently verified against account, wallet, team, environment, and eval
  APIs without inference. Its credential file had been created mode 0644; it is
  now mode 0600. No model credit was spent for any of this work.

- 2026-08-18 05:18 ET — Ran one explicitly capped real-provider verification
  of the new boundary after the unit, in-process, and environment-server gates
  passed. The single Qwen Flash `human_agent_relay` job disclosed a $0.181824
  unproxied contract maximum but could reserve at most $0.02. It completed in
  25.3 seconds at 96.25 with exact durable state, safety, source preservation,
  and one invalid Margin command. The proxy forwarded six requests, rejected
  none, reserved a conservative $0.008847, and independently observed 26,070
  prompt plus 2,168 completion tokens. The trace and wallet each reported
  $0.001. Both redacted artifacts validate, agree on the complete live policy,
  and bind candidate `live-budget-proxy-smoke-v1`; raw traces remain ignored.
  The experiment ledger now records 17 attempts, 16 completions, 193 model
  calls, and $0.0374 total wallet debit.

- 2026-08-18 05:52 ET — Completed the release and portability gates after the
  live-budget work. Margin passes 164 macOS tests and 112 isolated Linux tests;
  the Linux runner now selects the host architecture explicitly, so an old
  Intel Docker cache cannot create a false timeout on Apple silicon. The
  benchmark passes all 48 contracts under both the ordinary and Prime Python
  runtimes (six intentional Prime-only skips in the ordinary runtime), all six
  deterministic scenarios at 100, and both complete 59-request fake-model
  rehearsals through the live proxy. The distributable wheel now declares its
  HTTP client dependency, performs a real Intel Linux wheel smoke, and runs all
  extracted-source tests on a pinned native Python image with the matching
  manifest-verified Margin binary. The CI workflow uses the same supported
  Python and dependency boundary. The then-current package digests were
  `45d3c91c3c6f9b858e4d9ed5e1432e07fc4bdbbe82dc8481841d433644dd3d06`
  for the wheel and
  `4a1c30a416db0a173e85ad18d0d25859603cd7cdcc2bb2ece9946b4a6946bb2e`
  for the source archive. The combined Mac app/CLI zip and installer are also
  built, with digests
  `d051533f6c7cfda4307521d1668ca11449e99789a17bc94b9bc1f5377bcaf839`
  and
  `1ccec429adf23a1b680a4984e815e7d206256090e4198033eea2313a17ba2307`.
  A fresh 15-run app benchmark measured 288.431 ms median / 326.421 ms p95;
  100-process checks measured terminal help at 5.132 ms median / 5.800 ms p95
  and staging guidance at 6.139 ms median / 7.440 ms p95. No app or CLI launch
  source changed in this phase, and no further model credit was spent.

- 2026-08-18 06:05 ET — Adversarially hardened the live spend boundary without
  calling a model. The proxy now rejects duplicate JSON keys and content-length
  headers, transfer encoding, absolute-form routes, credential-bearing upstream
  URLs, non-Boolean streaming values, conflicting output limits, Boolean or
  non-finite policy numbers, and a canonicalized body that exceeds the request
  limit. Successful connections close explicitly, and only the validated route
  is forwarded. Reservations remain serialized under simultaneous requests.
  Provider-reported usage is now checked against each exact reservation; an
  excess permanently closes the gate for that run, is published as a bounded
  counter, and makes validation fail. Historic artifacts remain valid because
  the new evidence fields are backward-compatible. Both complete 59-request
  fake-model rehearsals pass with zero rejects, zero provider-bound violations,
  and an open latch. The benchmark now passes 51 contracts in both Python
  runtimes; the ordinary runtime retains six intentional Prime-only skips. The
  implementation digest is
  `f23fd21a19b2162238111ff3898108e1ef38f33a380e36d3742c0174e46f74b3`.
  The hardened Linux-verified wheel is
  `41aa1811cf420256e60a61322af5f62fabff86044590b5288505c3bfb673b1d7`;
  its source archive is
  `6d692b15541825bd3b9bf1ef91e96446a8c4a41e9a7b30aa1dbd08891ccc3e4b`.

- 2026-08-18 06:17 ET — Turned the comparison-control contract into progressive,
  machine-readable release guidance without weakening its fail-closed boundary.
  `marginbench controls` now catalogs the single-agent, plain-Markdown,
  Margin-plus-shell, and no-exchange tracks alongside the primary track. Only
  `role-separated-margin-only-v1` is runnable; every unfinished profile carries
  stable `blockingGates` describing the evidence it still needs, and the schema
  requires runnable profiles to have no blockers and gated profiles to have at
  least one. Catalog values are deep-copied so a caller cannot mutate later
  results. The complete benchmark again passes 51 contracts in both Python
  runtimes, all six deterministic scenarios at 100, and both 59-request
  fake-model rehearsals with zero rejects or provider-bound violations. A clean
  extracted source package passes its 51 available tests with six intentional
  Prime-only skips, and the installed Intel Linux wheel passes self-test. No
  paid call was made. The implementation digest is
  `1f70155a6cada26b8c51ecbb4c7e59dbb476ffb9552ef3a9cb7e616c096e0c8e`.
  The final Linux-verified wheel is
  `d6b57497a55a9b8cef6718ff3afa156297e936e9ff83849f26a44294ce5f2f76`;
  its source archive is
  `ecd8065c151dd4a4a1e00ca81378dde5bcd4a3a83e4ec18f9cfa11402d9a9457`.
  Packaging and CI now also inspect both archive member lists and fail if a
  run trace, key, transcript, raw prompt, temporary tree, environment file, or
  cache path appears. The rule has executable positive and false-positive
  checks, and the clean package retained the same digests.

- 2026-08-18 06:31 ET — Added the first executable groundwork for the
  single-continuing-agent control without making it runnable. Study and execution
  plans now distinguish logical roles from actual model processes, trace seats,
  and phase policy. A 24-case `single-agent-margin-v1` plan therefore records 44
  logical role turns but 24 model processes per candidate, with one `agent` trace
  per episode and serial stable role phases. The normal profile retains 44
  processes. Prime cost construction now derives from the explicit process count
  rather than inferring it from roles, but both the reference runner and paid
  controller continue to reject the unfinished profile before work or spend.
  Schema validation recomputes every topology field and aggregate. The benchmark
  passes 52 contracts in both Python runtimes, all six reference scenarios at
  100, and both complete fake-model rehearsals. A clean archive and installed
  wheel pass the same gates, and the sensitive-path exclusion remains active. No
  paid call was made. The implementation digest is
  `e5de2cf72482f08dab1755b91a7c5ed4eb50e093889a5656cbdcec188fbcf887`.
  The current Linux-verified wheel is
  `7150f9814ec5bfd87dbaead8ae6247ac9995b3e411705ba307de1565c2a4c3e4`;
  its source archive is
  `7df424e69e2355924c45b51afc9fcd363ca2ba2e671a2248bbe7ceddb7c7585e`.

- 2026-08-18 06:37 ET — Implemented and tested the trusted phase-identity seam
  for the still-gated continuing-agent control. A controller advances only
  through the frozen role order, permits exactly one winner under concurrent
  advance attempts, writes a bounded atomic mode-0600 identity outside the
  workspace, and refuses symlink, replay, out-of-order, malformed, or exhausted
  state. The Margin MCP adapter reads that binding for each tool call rather than
  using model-supplied identity. A live MCP-server test proves one running server
  switches from the exact author to reviewer, while a contribution test proves
  a static attacker-selected identity is ignored. The Prime task also has a
  promptless projection for the future continuing exchange. The control remains
  non-runnable because that exchange and its six-scenario local/served matrices
  are not yet wired. The benchmark passes 54 contracts in both Python runtimes
  (seven expected Prime-only skips in the ordinary runtime), all six reference
  scenarios at 100, and clean-package verification. No paid call was made. The
  implementation digest is
  `2e674ca2b0e132032deae7b2371a5321ee82a2b6242b9e69abf4eaee499fcd18`.
  The current Linux-verified wheel is
  `ec22af54c8d4c7c704c7b0a51b90aa9b6db7845e77d42f34917733d6ec993e31`;
  its source archive is
  `424c47304b55cce92445b0eb0ec3c828d4c0df3fba5379350a9f3029b5de2cd2`.

- 2026-08-18 06:57 ET — Wired the trusted identity controller into a real
  promptless continuing Verifiers interaction without enabling the control.
  Existing role briefs arrive as separate user turns in stable phase/seat order,
  the model retains one transcript, same-phase work is serialized, scripted
  events retain their boundaries, and early termination still advances the
  deterministic external world. A disposable source snapshot changed only the
  control status and ran the complete fake model: 6/6 scenarios scored 100 both
  in process and through the environment server, with one trace per episode, 59
  forwarded requests, zero rejects or provider-bound violations, and no paid
  inference. That run found and fixed two harness defects: cases without an
  initial human event had not precreated the private control directory, and the
  preflight reader retained only the first reward from a batched trace envelope.
  The corrected release gate now collects every reward and derives its expected
  trace count from the selected topology: 11 role traces for the primary track
  and six continuing-agent traces for the control. Both defects now have
  regressions, and the primary in-process and served release gates pass again.
  The checked-in profile still refuses all execution
  because compute-matched live limits/costing and explicit logical-actor versus
  trace-seat publication remain incomplete. The benchmark passes 57 contracts
  in both Python runtimes (eight expected Prime-only skips in the ordinary
  runtime), and its clean package passes all available checks. No paid call was
  made. The implementation digest is
  `5cef878ec960ebdaf6bdfddf398f765d94caf6b6afe3112f76873bf734433f46`.
  The current Linux-verified wheel is
  `402e6a31b46a5ade48febf0abb96b58126297ea347be99c01ea8308c7778174b`;
  its source archive is
  `ee1aaeb9ff08292967981f33d4c46f4f9ae65f1391819d9c452c281b63086160`.

- 2026-08-18 07:10 ET — Completed and promoted the compute-matched continuing
  agent control. Provider and paired-study accounting now distinguish logical
  role work from actual model processes: a two-role case receives one process
  with the sum of both roles' turn and token limits, while retaining the same
  conservative provider bound as two isolated role processes. Redacted traces
  and run artifacts publish the original logical actors separately from the
  single `agent` trace seat, and independent validation rejects altered process,
  seat, phase, identity, or pricing metadata. The permanent release target ran
  all six cases both in process and through the environment server: 6/6 at 100,
  six traces, 59 forwarded fake-model requests, zero rejects or provider-bound
  violations, and no paid inference in each mode. A paired-plan regression
  proves equal logical work and equal worst-case cost with half the processes on
  a two-role case. Both Python runtimes pass 59 contracts; clean source/wheel
  verification passes. The implementation digest is
  `cf6b4c08710932f0a123728fd6f9a04c5d92db88eda8e9cc8423c74af5ff598e`.
  The Linux-verified wheel is
  `ad797f9bf43a6cdaa9a9c13fefe253e47587797a78f7ec0d1fd4ad7124b2feec`;
  its source archive is
  `f7a0b995563212ccb14b96ac42de88b55c5efcb4274a93a5a7ff3f566620266f`.

- 2026-08-18 07:20 ET — Repeated the continuing-agent served gate against a
  freshly generated private holdout key. All six hidden variants scored 100 in
  six traces over 59 fake-model requests, with zero rejects, zero provider-bound
  violations, and no paid inference. The temporary key was overwritten and
  removed. CI now repeats this private served control gate before removing its
  own ephemeral key, preventing the public deterministic fixtures from being
  the only evidence for the promoted topology.

- 2026-08-18 07:23 ET — Audited the low-level no-spend paid-plan projection for
  a two-role continuing case. It now publishes and enforces the same effective
  ceiling: one agent process, 24 calls at most from two 12-turn role budgets,
  and a $0.167190 conservative contract bound in the dry fixture. Mixed
  continuing scenarios with different role counts fail with a concise error
  before authentication, output creation, or spend, rather than receiving an
  unfair shared ceiling. No model call was made.

- 2026-08-18 07:25 ET — Expanded complete 24-case, two-candidate schedules for
  both implemented profiles without inference. Each schedule contains 88
  logical role runs. The role-separated profile schedules 88 model processes;
  the continuing profile schedules 48, while summing the same logical compute
  into those processes. With a 65,536-token prompt contract both independently
  produce the same $7.850568 worst-case bound and the same $2.40 enforced cap.
  Substituting the audited one-million-token provider contract reproduces the
  disclosed $96.662016 worst case for either schedule. This demonstrates that
  topology changes process count without silently changing work or admission
  cost. No model call was made.

- 2026-08-18 07:27 ET — Re-ran the launch gate after the benchmark and control
  work. Fifteen warm app launches measured 286.610 ms median and 289.237 ms p95;
  100 direct CLI help launches measured 5.191 ms median and 5.938 ms p95. All
  benchmark/provider code remains outside the Mac app launch path, and the
  measurements show no responsiveness regression.

- 2026-08-18 07:29 ET — Re-ran the complete architecture-pinned Linux gate on
  the frozen release candidate. All 112 portable tests passed across 19
  isolated suites. This final check used no model inference and did not alter
  the release artifacts.

- 2026-08-18 07:35 ET — Verified every shipped agent-onboarding help path and
  all five bounded capability projections. A new 100-process measurement of
  the final 0.3.2 CLI recorded 5.247 ms median / 5.832 ms p95 for help and
  7.441 ms median / 8.119 ms p95 for the 69,995-byte full capability catalog.
  The clean-package rebuild reproduced both published package hashes exactly.

## Next statistically useful paid run

The next useful experiment is not another public one-off. It is a paired
interface comparison over all six workflows with four private repetitions: 24
matched episodes per candidate, 44 role processes per candidate, and exactly
balanced 12/12 AB/BA ordering. That is the default study and exceeds the
20-episode promotion minimum.

The official 1M-token context resolves the factual uncertainty, but it exposes
an intentionally conservative budget problem. At Qwen Flash's current Prime
price, 2,400 output tokens, 12 turns, three possible upstream attempts per turn,
and $0.0002 rounding allowance, the worst-case bound is $48.331008 per candidate
or $96.662016 for the pair. The observed three-cell calibration cost only
$0.0097, but observed cost is not a safe admission limit. Before a broad private
study, the new trusted request proxy now hard-rejects oversized prompts and
enforces cumulative reservations before forwarding each model call. The paired
planner now preserves the $96.662016 contract maximum separately while allowing
an explicit $0.05 live cap on each of 48 jobs: the enforceable study maximum is
$2.40 under a $3 admission cap, and the first matched pair is at most $0.10.
That no-model plan preserves a $190 wallet reserve. The next paid step, if
chosen, is only that first private matched pair; inspect it before allowing the
remaining 46 jobs. The remaining $199.9487 balance is sufficient, so no
additional credits are requested.

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
