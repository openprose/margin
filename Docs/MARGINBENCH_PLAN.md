# MarginBench build plan

Last updated: 2026-08-21 05:12 ET

MarginBench is the working name for a portable, execution-scored benchmark for
human-to-agent and agent-to-agent collaboration over Markdown workspaces. The
benchmark core belongs to Margin, not to any model provider. Prime Intellect is
the first hosted adapter, evaluation venue, and possible training backend.

This document is the live checklist for the overnight build phase and its
morning verification continuation. Update the status and evidence here as each
gate is crossed.

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
**$196.7947**. The **$3.1914** difference is an account-wide wallet movement,
not an attribution claim for this benchmark; redacted run receipts remain the
authority for experiment-specific reported cost.

| Gate | Maximum cumulative spend | Purpose | Status |
| --- | ---: | --- | --- |
| 0 | $0 | Install, login, local tests, container builds, dry runs | Complete |
| 1 | $2 | One tiny end-to-end hosted smoke test | Complete; $0.0017 first valid smoke |
| 2 | $15 | Cheap-model calibration on a small public-development slice | Complete; cumulative debit $0.0394 |
| 3 | $50 | Paired comparisons of promising CLI/manual variants | In progress; multiple valid pairs plus one $0.0014 censored provider-accounting incident |
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
- [x] Add the compute-matched single continuing-agent control and pass its full
  local, served, identity, accounting, privacy, and validation gates.
- [x] Add the representation-neutral role-separated plain-Markdown control.
- [ ] Add the no-exchange floor and remotely isolated Margin-plus-shell control.
- [x] Implement the bounded plain-Markdown fact ledger, strict byte
  parser/encoder, public schema, adversarial format tests, and expected-fact
  projection across all nine workflows while keeping the control locked.
- [x] Implement the local confined plain-file gateway with bounded list/read,
  exact compare-and-swap atomic writes, trusted writer events, and adversarial
  traversal, link, stale-write, concurrency, size, and format tests.
- [x] Add a schema-backed partial neutral assessment for exact facts, source
  integrity, historical all-or-none visibility, first-writer attribution, and
  decision identity, then add trusted read-before-action continuity and required
  stale-write recovery from a private cross-process event record; explicitly
  leave efficiency and any overall score unevaluated.
- [x] Add the progressively disclosed, single-tool plain workspace surface and
  prove it starts in Prime's subprocess tool server with no shell or Margin
  executable.
- [x] Add answer-preserving plain-role prompt projections with five-seed checks
  across all workflows for boundedness, identity binding, Margin-command
  removal, and role-private information separation.
- [x] Pass one complete two-role Prime development workflow through separate
  served sessions and record content-free call, byte, latency, and available
  token observations while keeping the paid profile locked.
- [x] Extend the no-model Prime served preflight across all nine workflows with
  a versioned, schema-validated, content-free receipt.
- [x] Freeze descriptive cross-profile efficiency reporting as a source-bound
  vector of wall time, calls, failures, bytes, tool time, tokens, and cost;
  preserve absent measurements as null and prohibit scalar ranking.
- [x] Independently audit prompt equivalence and prove role-process transcript
  isolation outside the trusted scripted policy before enabling a real-model
  plain-Markdown control cell.
- [x] Add topology-aware dry planning for gated controls: logical roles,
  model-process counts, trace seats, and phase policy are distinct and validated;
  execution remains refused until each profile's complete gates pass.
- [x] Freeze the fairness, identity, cost, isolation, and release contract for
  those controls in `Docs/MARGINBENCH_CONTROLS.md`; none is marked runnable
  before its complete gate lands.
- [x] Add reference, idle, spam, fake-agent, and adversarial tests with no paid
  model calls. The remaining control variants are benchmark breadth, not a
  correctness blocker.
  The control catalog and fail-closed execution gates are now frozen; the
  primary role-separated, compute-matched continuing-agent, and plain-Markdown
  profiles are runnable. The no-exchange and shell profiles remain gated on
  task-neutral aggregation or remote isolation.

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
- [x] Publish bounded redacted crossover bundles and add a fail-closed audit
  that validates their files, bindings, paired coverage, and recomputed report
  without reading or echoing raw traces.

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

- 2026-08-18 07:37 ET — Froze the first design draft for a fair ordinary-
  Markdown comparison. It defines a common fact projection, a visible
  `COLLABORATION.md` interchange, representation-neutral dimensions, exact
  success conditions for all six workflows, intermediate all-or-none
  visibility, and the adversarial gates required before the control can run.
  No paid or model-backed execution was enabled.

- 2026-08-18 07:51 ET — Corrected the distributable benchmark card's stale
  description of the now-runnable continuing-agent control, then rebuilt from
  the source archive and repeated all 59 clean-container tests plus the
  installed-wheel six-case self-test. The final wheel is
  `7da1b10fc0e471607cb6f8a74c8238d9159d949a9e950643786589c0f3b83ee0`;
  the final source archive is
  `5c3547ab616f93db2a862a9694e648916c819c6b16bf657976ac1aba470263d4`.
  No inference was invoked.

- 2026-08-18 07:54 ET — Removed two source-checkout-only links from the
  standalone package card, rebuilt again from its source archive, and repeated
  the same installed-wheel self-test and 59-test clean-container gate. The
  final public wheel is
  `2446d5e596baacaf285d956aa550d6c7d39cd5573b4081ee29ed2b674cca3f9f`;
  the final source archive is
  `cb30db550c983d8a7eae2edc29bf7f4f3c0bfb48f71380287517045c8ba46326`.
  No inference was invoked.

- 2026-08-18 07:56 ET — Removed the final source-archive-only hyperlink from
  the README that becomes wheel metadata, then completed the same independent
  rebuild and clean-container gates. The final self-contained wheel is
  `58b0b51b7bab472ee206abfd9069f8b9f423ee481c7ef13847f7e45fe4c7bc55`;
  the final source archive is
  `cd8b91b4dcde44880df37bb84eceb3cc55e0b0ae0891e230c3744b5664227760`.
  No inference was invoked.

- 2026-08-18 10:33 ET — Attempted the authorized public topology calibration
  on the exact `agent_agent_handoff` repetition-0 case. The role-separated half
  completed at 96.25 with exact outcome, intact source, one invalid command,
  ten model calls, 39.840 seconds wall time, and $0.0017 observed debit. The
  continuing-agent half was invalid: Prime reported 1,202 completion tokens
  against the 1,200-token reservation, the live gate closed after one forwarded
  call, three later calls were rejected, and $0.0002 was charged. A mistaken
  natural-language balance probe before the experiment cost another $0.0001;
  total debit for the phase was therefore $0.0020, leaving $199.9467. No score
  comparison was recorded and no paid retry ran. The harness now prices a
  separate eight-token provider wrapper allowance without increasing the
  requested generation limit, marks any infrastructure code or errored role as
  incomplete, creates raw trace roots at mode 0700, and can validate redacted
  infrastructure receipts. During local verification, a pre-existing race in
  the scripted concurrent-writer rehearsal was also reproduced: after a real
  write conflict the fake agent reread but did not retry. That recovery path is
  fixed and passed 10/10 targeted served runs. The complete role-separated and
  continuing-agent matrices now pass in-process and through the environment
  server; all 63 benchmark tests pass. The fresh two-half retry plan is dry and
  compute-matched at a $0.049 cap per half ($0.098 combined), but remains
  unexecuted pending a separate paid-retry decision. The repaired source
  archive then rebuilt independently and passed all 63 discovered clean-package
  tests (eight expected Prime-only skips); its installed wheel passed the
  six-scenario 100/100 self-test. The replacement wheel is
  `8454236f270122921a70e588280023663fcc36a60bba2fa5b5bcec638a8f93b0`
  and the source archive is
  `b3b6a78e89ffa7c9e4ea6797923588cd178b4dd5ab7aecb7013d4780fe8653df`.

- 2026-08-18 11:03 ET — Ran the separately authorized fresh topology pair
  under the repaired harness. Both halves used the same public
  `agent_agent_handoff` repetition-0 fingerprint, model, temperature, logical
  actors, Margin binary, 1,208-token billing ceiling, and $2.185707 disclosed
  contract bound, with independent $0.049 live caps. The role-separated half
  completed at 96.25 with exact outcome, intact source, one invalid command,
  ten model calls, and $0.0016 observed debit. The continuing agent reached the
  exact outcome at a diagnostic score of 100 with zero invalid commands, but
  one recorded model call returned an upstream 429 before later calls
  succeeded. The frozen policy classifies any provider rate limit as an
  infrastructure error, so that score is not recorded and the halves are not
  compared. The continuing half used eleven model calls and $0.0026. Fresh-pair
  debit was $0.0042; total debit from the original $199.9861 balance is now
  $0.0436, leaving $199.9425. Both redacted infrastructure/completion artifacts
  validate, raw traces remain private and uncommitted, and no further paid
  retry ran. Before any more inference, decide prospectively whether a
  transparently recovered, pre-budgeted provider retry invalidates an episode
  or is disclosed as execution metadata.

## Next statistically useful paid run

The provider-error policy, wrapper-token allowance, and live request gate are
now frozen and tested. The first four-family public crossover produced four
valid pairs. Its most actionable signal is command discoverability in
multi-file review, so the next run should be a small interface calibration on
the two affected public families while holding model, cases, roles, and limits
fixed. A fresh generated-case check follows only if that mechanism improves.

The later promotion experiment remains a paired interface comparison with at
least 20 private matched episodes and balanced candidate order. It should not
start merely because a four-pair public mean is favorable; the current score
and speed intervals include both topologies.

The official 1M-token context resolves the factual uncertainty, but it exposes
an intentionally conservative budget problem. At Qwen Flash's current Prime
price, 2,400 requested output tokens plus eight bounded provider wrapper tokens,
12 turns, three possible upstream attempts per turn, and $0.0002 rounding
allowance, the worst-case bound is $48.332656 per candidate or $96.665312 for
the pair. Observed calibration cost is tiny, but observed cost is not a safe
admission limit. Before a broad private study, the trusted request proxy
hard-rejects oversized prompts and
enforces cumulative reservations before forwarding each model call. The paired
planner now preserves the $96.665312 contract maximum separately while allowing
an explicit $0.05 live cap on each of 48 jobs: the enforceable study maximum is
$2.40 under a $3 admission cap, and the first matched pair is at most $0.10.
That no-model plan preserves a $190 wallet reserve. The remaining $199.4097
balance is sufficient, so no additional credits are requested.

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

## 2026-08-18 overnight continuation

- Froze a nine-family collaboration-demand catalog and a paired crossover
  design comparing fresh role contexts with one compute-matched continuing
  context. The zero-model reference study completed 180 matched pairs and
  recovered the expected mechanical speedup only for genuinely independent
  parallel shards.
- Added exact, atomic `comments reply --resolve`, actionable inbox paths and
  revision-bound templates, phase-specific identity recovery, and bounded
  workflow capability projections. All of these remain off the Mac app launch
  path.
- Added strict multi-run crossover evidence assembly so separately validated
  cells can follow the plan's interleaved topology order. The analyzer rejects
  duplicate cases, contract drift, mismatched builds, missing cells, and
  infrastructure-invalid runs.
- Added privacy-safe trace diagnostics that retain command names, flag names,
  outcomes, and error-code counts per command shape while discarding argument
  values, paths, IDs, prompts, stdout, stderr, and document content.
- Ran the first four-family Qwen Flash public slice: eight safe cells, four
  matched pairs, $0.0178 total observed spend, and a validated combined report.
  Role separation descriptively led two cases, continuing led one, and one was
  inconclusive. The overall intervals crossed both sides and the report remains
  `insufficient-data` by design.
- The evidence-driven interface pass now accepts natural capability aliases
  such as `comments`, supports `margin man COMMAND SUBCOMMAND`, returns exact
  per-file action paths and annotation revisions from directory context, and no
  longer suggests revision zero for ambiguous multi-file work.

The next paid gate is not a broad leaderboard run. First repeat the two
friction-heavy public cases on the new interface candidate under the same cheap
model and limits. If command errors fall without changing correctness, confirm
on fresh generated cases. Only then spend on rotating private repetitions or a
larger model matrix. The current Prime balance is $199.4097, so no additional
credits are needed.

## 2026-08-19 evidence-driven continuation

- Froze and ran `margin-0.3.2-actionable-context-v15` on the two
  friction-heavy public cases. All four cells were safe and source-preserving,
  no cell was retried, and observed spend was $0.0064. Role separation led
  descriptively in both cases, but two pairs are below the frozen minimum for a
  directional claim. Privacy-safe trace shapes localized three malformed
  manual lookups and one unsupported `finding` label.
- Added a bounded, machine-readable `margin man ... --json` envelope and the
  natural `finding` alias for the canonical issue contribution. Exact leaf help
  remains available as plain text, and the new path performs no workspace or
  network work. CLI contract coverage proves JSON schema, size, pretty-print,
  list, and alias persistence behavior.
- Added a resumable paid-crossover controller. It freezes the candidate,
  binary, cases, plan, pricing and limits; verifies the exact keyed case set;
  runs cells serially; checks the wallet reserve before every remaining cell;
  writes an attempt marker before inference; never retries automatically; and
  resumes only a verified contiguous prefix. Its public plan and completion
  receipts have bounded schemas and semantic validation.
- The controller ran the exact four-cell v16 plan for $0.0068 against a $0.12
  hard cap, leaving $199.4131 and the $80 reserve untouched. All cells were safe
  and source-preserving. Independent shards favored continuing on this sample
  (98 versus 93.25); specialist audit favored role separation (100 versus
  73.75). The aggregate descriptive role-separated lead was 10.75 points, but
  its interval crossed zero and the report remains `insufficient-data`.
- The v16 traces contain none of the targeted manual or contribution-kind
  syntax failures. One role-separated shard agent guessed revision one after
  reading revision zero; the CLI rejected the stale precondition and the agent
  recovered with zero. The continuing specialist stopped after the first
  contribution and omitted the independent audit. Frozen historical scores
  were not rescored or rewritten.
- Final v16 evidence is at
  `Evals/marginbench/results/crossover/v16/`; the crossover report
  validates at SHA-256
  `a035e085575a58650e47382b36e4a7a2358accc1b4a8f747ce41168343d83475`.
  Only redacted run and summary artifacts are published; raw traces stay in the
  ignored private controller workspace.
- Candidate v17 made the progressive manual genuinely structured: JSON pages
  include bounded typed command contracts and explicit next queries, exact leaf
  pages include exactly one contract, and broad topics disclose only their
  relevant commands. Context now labels annotation revisions as observed
  pre-write values and states that zero is valid and must not be incremented.
  The full 170-test product suite, both 85-test Python suites, lint, the
  nine-scenario 100/100 self-test, and both isolated served topology rehearsals
  passed without paid inference.
- A separately frozen two-cell shard probe then completed for $0.0034 with no
  retries. Role separation scored 100 with six commands and no invalid command;
  continuing scored 98 with eight commands and no invalid command. The targeted
  revision, manual, and kind errors were absent. Because this is one stochastic
  public repeat, it is evidence for the mechanism, not a promotion claim. Its
  validated report SHA-256 is
  `f3401b68135aac4ab0d0baa726e43aa0e46998283602796f74baccc4857f9d66`.
- New-process measurements on the v17 release recorded 6.044 ms median / 7.367
  ms p95 for help, 6.861 / 8.357 ms for structured comment-manual JSON, and
  7.183 / 8.477 ms for the focused comment capability catalog. Fifteen native
  app launches measured 320.756 ms median / 332.541 ms p95 and 162.031 MiB
  median RSS. The manual and benchmark remain outside the AppKit launch path.
- The plain-Markdown representation control is now runnable after four
  independent zero-cost gates. The prompt audit passed 85/85 role projections;
  the served reference passed all nine workflows; the isolation proof observed
  17 fresh role processes, 105 local requests, 88 same-role continuation
  canaries, and zero cross-role leaks; and the exact Prime production command
  validated all nine non-scalar results plus both official artifact formats.
  The production rehearsal also exposed and fixed a negative multi-turn token
  counter in Prime's branch convenience metric by using each call's
  provider-reported usage instead.
- Cross-representation reporting is deliberately not a leaderboard score. It
  preserves task outcomes, integrity, attribution, continuity, recovery, wall
  time, tool calls/failures/bytes/time, model tokens, and cost as a resource
  vector. The schema permanently sets `scalarRankingPermitted: false` and
  records no winner.
- The first real plain-Markdown control cell on the exact v17 parallel-shards
  case cost $0.0018 and failed for two representation-level reasons: the task
  still sounded like a source edit, and the ledger required an agent to count
  UTF-8 bytes by hand. The format now uses a canonical `Body JSON` string,
  source-versus-fact wording is explicit, guide calls accept harmless path
  context, and format failures return bounded recovery details. Both 143-test
  Python suites and all nine exact no-model production rehearsals passed after
  the change.
- One prospectively capped, exact v2 retest then passed every neutral outcome
  and safety check for $0.0019, leaving $199.4060. It preserved both source
  documents and recovered from the concurrent write. The matched v17 Margin
  cell also passed; descriptively, Margin used 8 model calls, 6 command round
  trips, 19.930 seconds, and $0.0014, while the v2 ledger used 15 model calls,
  17 tool round trips, 27.985 seconds, and $0.0019. This single public case is a
  resource vector, not a scalar winner. Both the failed v1 artifact and the v2
  repair are retained for auditability.

## Frozen next representation calibration

Before any further inference, freeze one different collaboration shape rather
than tuning again on parallel shards:

- case: public-development `agent_agent_handoff` repetition 1, episode
  `agent_agent_handoff:1:9d4a9f0ce734`, fingerprint
  `9d4a9f0ce734fdf5e617982bd46fd31c9682ad6e3df193214184bd07a9673edf`;
- order: Margin v17 first, plain-Markdown v2 second, chosen by the low bit of
  SHA-256(`fingerprint|representation-v1`);
- model: `qwen/qwen3.7-flash`, temperature zero, two fresh role processes;
- limits per role: 8 turns, 40,000 input tokens, 6,000 output tokens, 16,000
  total tokens, 1,800 requested tokens per call, and the same provider bounds
  and retry policy as the completed parallel-shards representation probe;
- spend: no automatic retry, $0.03 live cap and $0.04 hard admission cap per
  cell, with the normal five-minute start interval;
- interpretation: exact common outcomes and source safety gate the resource
  vector. No scalar winner, promotion claim, or broad representation claim is
  permitted from one pair.

This case tests necessary durable information transfer between fresh agents,
which is structurally different from the already-observed independent parallel
work. If either cell is unsafe, incomplete, or infrastructure-invalid, stop the
pair and classify the failure before spending again.

The Margin half completed at 100 with seven commands, no invalid command,
39.408 seconds, intact source, and $0.0018 debit. Its model work was valid, but
the publisher rejected `track: representation` because the ordinary Margin run
schema had not yet admitted the already-supported representation track. The
pair stopped before the plain half. The schema is corrected and covered; the
immutable private checkpoint was validated, cross-checked, and promoted without
another model call. A new `promote-checkpoint` command now makes this recovery
atomic, idempotent, and fail-closed for both Margin and neutral summary/run
pairs.

Because the repair necessarily changed the benchmark implementation digest,
the unrun plain half cannot form a strictly matched pair with that completed
Margin artifact. It will not be launched. The replacement frozen case is the
next public-development repetition:

- case `agent_agent_handoff:2:fb5dc006bfbd`, fingerprint
  `fb5dc006bfbd688c652e8122d99769b087642d970ed1adae764ed19983d2808c`;
- deterministic order remains Margin first, then plain Markdown;
- every model, topology, token, timeout, price, cap, retry, outcome, safety,
  and interpretation rule above remains unchanged;
- no implementation file may change between the two cells. Any required code
  change cancels the pair and requires a new case identity.

The replacement pair completed with no code change between cells. Margin
passed every check with 8 commands, 10 model calls, 41.499 seconds, and $0.0016.
The plain ledger preserved the source and successfully carried the handoff and
reply with 11 tool calls, 12 model calls, 54.225 seconds, and $0.0016, but the
frozen scorer marked its outcome partial because it repeated the root's audience
on the reply. That was classified as a representation-bias defect in the
scorer, not lost collaboration state: only an exact inherited audience is now
normalized, and unrelated audiences still fail. The old artifact remains
unchanged.

A separate audit found that the old public records did not fully capture
temperature, wall and upstream timeouts, or launch pacing. The actual commands
used the same values, but a third party cannot prove that from the pair alone.
Future manifests include them, and the efficiency report now verifies 36 hashed
experiment-contract fields.
It distinguishes matched settings, named mismatches, and missing metadata;
episode identity alone is no longer sufficient. This pair is consequently
classified `insufficient-metadata` rather than silently matched. No further
paid run should begin until the new publisher and contract report pass every
free gate.

## Frozen contract-verification pair

The free gates passed after that repair: both Python environments completed
150 tests, the all-nine exact Prime production rehearsal passed, lint and diff
checks were clean, and the generated efficiency report validated. One fresh
pair is pre-registered to verify the publisher and scorer prospectively:

- case `agent_agent_handoff:3:177f1b27899f`, fingerprint
  `177f1b27899f11fce8edd82bb645327e8dd899b5d67a6faa2e5f99d6e1ddb2fb`;
- deterministic order Margin v17 first, then plain Markdown v2;
- benchmark implementation SHA-256
  `0cb9c0b8bc32787e6e182a095c1d617d40b905932ba60a91c63224f937b4814b`;
- Margin binary SHA-256
  `63896b7b5afda0691a8c7855e50f9b989cd7b519eb15e51713cf1096175f7964`;
- Qwen 3.7 Flash, temperature zero, two fresh role processes, 8 turns,
  1,800 requested output tokens per call, 40,000/6,000/16,000 agent token
  bounds, 180-second rollout timeout, 300-second wall timeout, 120-second
  upstream timeout, and 300-second minimum start interval;
- identical request ceiling, retry allowance, prices, and independent $0.03
  live / $0.04 admission caps; no automatic retry;
- interpretation remains non-scalar. Exact outcome and safety are reported
  separately from time, calls, tokens, and cost. The pair is comparable only if
  all 36 public contract fields independently validate as matched.

No benchmark implementation file may change between these cells. A failure in
the first cell stops the pair for classification; a provider or publisher
incident is not a task score.

The pair completed exactly under that contract. Both sides passed every task,
integrity, attribution, continuity, recovery, and source-safety check. Margin
used 6 CLI actions and 8 model calls, took 45.606 seconds, and cost $0.0015. The
plain ledger used 15 tool actions and 15 model calls, took 63.771 seconds, and
cost $0.0025; each role recovered from one failed write. The independent
efficiency report verified all 36 contract fields as matched, named no
difference or missing field, validated at SHA-256
`ee405cb0ecac6563d95aa611aff8886b2508e16fa444ef5527c4b9be12c59616`,
and still records no winner. This is the first fully provenance-complete
real-model representation pair. It is one public handoff case, so the resource
shape is diagnostic rather than a broad representation claim.

## Frozen nine-family topology breadth study

At 2026-08-19 05:08 ET, the next real-model study was frozen before inference.
It is an exploratory breadth map, not a leaderboard or directional claim:

- all nine public-development challenge families, repetition zero, each run
  once with a continuing agent and once with fresh role-separated agents;
- frozen crossover-plan SHA-256
  `a1d6cce2b1d58762deedff4041619ee0002c0a2bb32fe106ff1f077bf549834b`;
- frozen paid-plan ID
  `sha256:07a7ee8d89719edc8ee5b5643ac65c7846ee1d81e2812a0a7b6a806d18fee300`
  and file SHA-256
  `f6a70acff5f5b18c6853ff6c59c18c22e182469b6870571e4e3facb5682ebbb6`;
- benchmark implementation SHA-256
  `daecf8b89e9419cf9c95c710dd1e8156a51fb9623e27c77c8a3952373b0be1ea`;
- candidate `margin-0.3.2-structured-manual-v17`, Margin binary SHA-256
  `63896b7b5afda0691a8c7855e50f9b989cd7b519eb15e51713cf1096175f7964`;
- Qwen 3.7 Flash at temperature zero, with the live Prime catalog price of
  $0.03 per million input tokens and $0.13 per million output tokens;
- 8 turns, 1,800 requested output tokens per call, 40,000/6,000/16,000 agent
  token limits, 180-second rollout, 300-second wall, 120-second upstream, and
  a 300-second shared paid-start interval;
- 18 serial cells, no automatic retry, an independently enforced $0.03 live
  cap per cell, a $0.54 whole-study ceiling, and a $190 wallet reserve. The
  read-only balance immediately before launch was $199.3970.

Before freezing this plan, both supported Python runtimes passed 152 tests,
both the Margin and plain-control paths passed all nine production-shaped
no-model rehearsals, lint and diff checks passed, and the signed v17 binary was
rebuilt and digest-checked. The controller now waits on the shared paid-start
marker before every cell and accepts a completed cell only if its full model,
candidate, topology, token/time limits, pricing, live-budget policy, and retry
contract equal this plan. The current schema remains backward-compatible with
older published plans that predate the two newly recorded pacing fields.

The frozen order begins with the complete suggestion-decision pair, then
distributed synthesis, directory handoff, human-agent relay, parallel shards,
specialist audit, agent-agent handoff, concurrent review, and staged multi-file
work. Any unsafe result, source damage, incomplete artifact, contract drift,
provider-bound violation, or uncertain attempt stops the campaign. With only
nine pairs, results may locate mechanisms and interface friction but cannot
support the benchmark's 20-pair directional threshold.

The study stopped after its fifth cell, as required. The complete
suggestion-decision pair was safe and exact: continuing scored 99.286 with an
outcome of 100, while role separation scored 100. The distributed-synthesis
fresh-role cell scored 100; its continuing match stayed safe but scored 80.536
after carrying the wrong action family across the phase boundary. It tried an
unsupported resolve flag on comment creation, then created and resolved a new
thread instead of replying to the durable handoff. Content-free diagnostics
confirmed that its second-phase instruction explicitly required both reply and
resolution, so this is phase interference rather than missing state.

The fifth cell completed the directory-handoff task at 100, but one of twelve
provider requests received an upstream 429. Its summary was therefore correctly
classified `PROVIDER_RATE_LIMIT`, excluded from evidence, and not retried. The
cost gate intentionally retained that request's worst-case reservation because
the error response carried no trustworthy usage. Four accepted cells cost
$0.0087; the excluded incident debited another $0.0036, leaving $199.3847. The
controller also exposed an uncaught validation exception after stopping; it now
reports the same incident cleanly without a traceback.

## Frozen paced replacement study

At 2026-08-19 05:44 ET, a separate replacement was frozen. It reuses the same
public cases specifically to isolate the orchestration change; no v18 score will
be pooled with its corresponding replacement observation.

- paid-plan ID
  `sha256:9cad298fee32832ec9584a5dc58fbc104d0f7abccacd6a92427a000a1579a7d9`;
- paid-plan file SHA-256
  `a0f4206ca694259e0c47ce0343f24414a8e84bcadaa7578a279f2f74866616af`;
- benchmark implementation SHA-256
  `2fa36aaf2f30730faf74930ba835fc36a8a94506a74b0f6ee43777eae3a5063e`;
- all prior model, candidate, task, token, timeout, price, cell-cap, aggregate
  cap, reserve, ordering, and no-retry conditions unchanged;
- a new six-second minimum interval between every provider request start,
  serialized at the shared loopback spend gate and recorded in each run's
  frozen experiment contract.

Before this replacement was frozen, both Python runtimes passed 153 tests,
including deterministic pacer and infrastructure-adoption regressions. Both
all-nine Margin rehearsals and all three all-nine plain-control rehearsals
passed again, as did lint, schema validation, historical publication audit, and
diff checks. Request pacing applies equally to both topologies. It may change
elapsed time, so only cells inside this one paced study are timing-comparable.

The paced replacement completed all 18 cells. Every pair passed workspace,
source-preservation, and safety checks; no provider request was rate-limited.
Observed spend was $0.0462 across 191 model calls, far below the $0.54 study cap
and the protected $190 wallet reserve. The audited public bundle is
`Evals/marginbench/results/crossover/v19/`, and the aggregate report reproduces
from its 18 redacted runs and summaries.

The nine-pair result remains explicitly insufficient for a directional claim.
Continuing context led four cases, fresh roles led two, and three were
inconclusive. The role-separated minus continuing mean score delta was -5.485
points with a paired 95% interval of -13.568 to 1.001. Fresh roles used 0.56
fewer model calls, 22,754 fewer prompt tokens, and $0.000644 less reported cost
per case on average. These are descriptive observations only.

The most useful diagnoses were structural. Fresh independent review helped in
the specialist case, while the serial handoff negative control strongly favored
continuity after the fresh author exhausted its first response budget without
acting. Both topologies struggled with staged multi-file work; atomicity held,
but plan inspection, refresh, and submission consumed too much of the turn
budget. Content-free trace shapes distinguished model output exhaustion, true
turn-limit stops, expected stale-write recovery, and CLI usage errors without
retaining prompts, document content, paths, identifiers, arguments, or streams.

Post-study CLI changes now provide atomic reply-and-resolve, precise recovery
for a misplaced suggestion command, cursor guidance for handoffs, and complete
next actions for stage inspection and stale-stage refresh. They are a new
candidate and must not be credited to v19. Before buying another breadth run,
add free regressions for each recovery path and test the candidate on one cheap
targeted handoff cell plus one staged multi-file cell. Expand to 20 fresh paired
cases only if those probes move the intended mechanism without a safety,
startup, or efficiency regression.

That targeted gate is now complete. The matched handoff cells both scored 100,
correcting an earlier premature causal interpretation. The first staged
candidate cell was excluded after a provider rate-limit response even though
its task state looked complete. A separately frozen replacement pair used a
ten-second request interval and no retry: v17 scored 25 with an unsafe workspace
outcome, while the recovery candidate scored 95.625 with a safe atomic result,
four fewer invalid commands, one fewer total command, and intact source. The
pair cost $0.0055 across 29 calls. Its audited redacted publication is under
`Evals/marginbench/results/candidate-studies/v20-stage-recovery-public-r0/`.
One public case cannot promote a candidate. It did identify the next small,
general interface correction: `stage list` now defaults to the nearest current
workspace instead of wasting an agent turn on a missing root argument. No more
paid inference is needed for this development cycle; the next paid evidence
should use fresh generated cases only after all free gates pass.

## Morning continuation closeout

The final tree passes 172 native tests, 156 MarginBench tests in each supported
Python runtime, lint, publication audit, both nine-family Margin rehearsals in
process and through the separate environment server, and all neutral-control
preflights. Every rehearsal reported `paidModelsInvoked:false`. The release
bundle passed its CLI, inspection, signing, and visible-window smoke checks.

The final local binary SHA-256 is
`87494945d38f99511b0bfd82b565e54d79ec005b183734aa139a8bcaf186a611`.
One hundred fresh invocations took 0.67 seconds for global help, 0.68 seconds
for `margin man`, and 0.69 seconds for stage-list help on this Mac. The CLI
change therefore adds no measurable startup work; workspace discovery occurs
only when `stage list` is actually invoked without a root.

The combined app-and-CLI zip and installer package were rebuilt and their
checksums verified. The app and helper are ad-hoc signed for local use. The
installer remains unsigned because this machine has no Installer/Developer ID
certificate; public notarized distribution still requires that identity.

The read-only Prime wallet check after all paid evidence reported $199.3243,
leaving more than the protected $190 reserve. No further model call was made
after the targeted replacement pair.

## 2026-08-20 published-baseline continuation

The continuation began by re-establishing the product and evidence baseline.
`main` now includes the public `v0.4.0` tag, the GitHub release workflow,
combined macOS app-and-CLI packages, separate Linux CLI archives, release audit
hardening, and the target-size startup matrix. The published v0.4.0 binary is
retained byte-for-byte as the comparison baseline rather than rebuilt from the
new working tree.

The current cycle alternated benchmark corrections and narrowly scoped CLI
changes:

| Step | Mechanism tested | Result | Decision |
| --- | --- | --- | --- |
| v31 | Put concrete actions before descriptive context | One Qwen pair improved by 27.9 points, but one pair is calibration only | Retain for further matched evidence |
| v32 | Compact the action-first view | One Luna pair scored 91.944 versus 92.5 for v31 | No improvement claim |
| v33 | Accept natural manual topics such as directory, folder, workspace, context, and inbox | One Luna pair used four fewer commands and two fewer model calls but scored 92.5 versus 94.583 | Keep the harmless aliases; do not claim quality gain |
| v34 | Include exact reply-and-resolve, thread verification, handoff creation, and handoff verification actions in brief context | In the valid counter-ordered Luna pair, v34 scored 96.25 versus 92.5, completed the required workflow, and was 4.58 seconds faster | Useful one-pair mechanism signal; not promotable |
| v35 | Redirect `margin man FILE.md` to a safe, bounded target workflow | A fresh Luna pair tied v34 at 100 with equal commands and no invalid calls; the redirect itself was not invoked | Safe but not yet causally exercised |
| v36 | Remove redundant prose and fields from brief context and halve its default source preview | A long-document/open-work fixture fell from 5,064 to 3,776 bytes while retaining executable reply, resolve, verification, read, and handoff actions | Keep behind permanent size and content regressions |
| v37 | Bound the default brief view of a wide directory while preserving explicit overrides | On the frozen 16-file/four-item-per-file probe, output fell from 52,383 to 7,377 bytes and median elapsed time from 57.423 to 22.015 ms in a counterbalanced 20-round comparison | Keep behind a wide-workspace regression; require a real task before claiming agent benefit |
| v38 | Add an opt-in wide-directory triage task and a compact filtered inbox | The exact 16-file/64-distractor reference completed at 100 in five commands; filtered inbox output fell from 11,440 to 3,215 bytes while still finding the one question outside brief context | Retain as an experimental scenario; buy no model run until the full release gates and a future paid plan are frozen |
| v39 | Align built-in agent teaching with the bounded defaults and tighten the new route oracle | Every manual page stopped overriding brief context with 16 files, filtered inbox examples became compact, and a deliberately reversed inbox-before-context trace now fails the route check despite completing the document | Keep as contract hardening; require future real-model evidence before promoting the experimental scenario |
| v40 | Make concurrent-work efficiency reflect the benchmark's prescribed recovery path | Running both Python contract suites under contention exposed a legitimate write collision: the reference agent recovered exactly as instructed but lost 0.769 points because the efficient-call allowance covered only the collision-free path. The scorer fixture now treats one failed write plus its required reread as fully efficient, and a deterministic regression constructs that six-call recovery | Keep as benchmark correction; do not interpret normal concurrency recovery as agent waste |
| v41 | Absorb safe annotation-only races inside typed contribution creation | Eight simultaneous distinct issues first proved that three retries were insufficient; a bounded eight-attempt implementation then passed ten consecutive eight-writer runs while preserving every identity, contribution, and source byte. In a 200-case side-by-side stress sample, the frozen v0.4.0 binary exposed 29 collision/recovery episodes and used six calls in each, while v41 exposed zero and used four calls in all 200; both arms remained 100 and safe | Keep as a measured CLI candidate; explicit revision guards and Markdown changes still fail closed, and model-free contention evidence is not a model-quality claim |
| v42 | Make concurrent contention a reproducible, schema-checked benchmark mechanism | The new model-free probe starts baseline and candidate together for 1,000 paired two-writer episodes, counterbalances submission order, binds the generated case set by digest, checks exact outcome/safety/source preservation, and records visible-conflict and command-count histograms. Under this deliberately stronger contention, the frozen v0.4.0 baseline surfaced 719 conflicts and used 5,438 visible calls; v41 surfaced none and used 4,000. Both scored 100 and preserved source | Keep the probe and retained report. Never require the baseline to collide, never treat mechanism evidence as model-quality evidence, and use real-model paired studies only for agent-performance claims |
| v43 | Prevent a broken comparison baseline from yielding a passing contention report | Final adversarial review found that the candidate gate was strict but the baseline arm was descriptive even for correctness. The report and independent validator now require both arms to score 100, pass safety, preserve source, and avoid invalid commands; only baseline collision frequency remains descriptive. A tampered-baseline regression fails the pass flag | Keep as benchmark-integrity hardening. The retained 1,000-pair evidence remains valid because both arms already met the stricter contract |
| v44 | Diagnose Linux XCTest stalls without weakening the product gate | Live LLDB capture identified the exact open swift-corelibs XCTest teardown deadlock (`ppoll` → Foundation run loop → XCTest expectation wait → teardown → `invokeTest`) with no active Margin frame. A strict per-test runner retries only that captured framework stack. A 200-process stress sample recovered four exact cases, a forced ordinary timeout failed closed, and four full 124-test gates passed, the last three with zero recoveries | Keep the narrow diagnostic classifier and its adversarial tests. Never treat an assertion, crash, debugger failure, product stack on any thread, or unclassified timeout as retryable |
| v45 | Generalize safe contention handling by operation meaning | A schema-checked 400-episode process matrix covered typed additions, suggestion additions, stale-safe suggestion rejection, source-changing acceptance, and cursor-bound handoffs at 2/4/8/16/32 actors. At 32 actors the candidate completed all suggestion additions and rejections while the baseline left 82 and 181 unfinished; acceptance still had one exact winner and handoff conflicts stayed visible. Startup remained flat | Keep the operation-specific boundary: only commutative metadata work may converge internally; source changes and provenance-sensitive handoffs still fail visibly |
| v46 | Turn suggestion contention into a causal agent experiment | The first natural-scheduler pair was safe but produced no conflict, and help telemetry overstated writes. A benchmark-only document-lock rendezvous now forces both first writes to share one evaluated base, focused help is classified as help, and verification is limited to list plus source read. Five old-CLI reference cases surfaced 2–4 conflicts and used 16–20 calls; the candidate remained at 12. In the corrected $0.0118 public pair, the old CLI exposed one forced error and recovered while the candidate exposed none; both scored 96.111 with 26 commands and 28 model turns | Keep the causal benchmark and retry mechanism. Do not claim agent-efficiency improvement: the candidate was 5.362 seconds faster but spent the saved recovery on redundant discovery and verification. Isolate built-in guidance next |
| v47 | Separate exact suggestion assignments from open-ended discovery | A $0.0093 matched public pair held the retry mechanism fixed. New guidance improved 96.944→97.222, 23→22 commands, 25→24 model turns, 46.263→44.005 seconds, and $0.0051→$0.0042, with every write adding `--expect`; both arms stayed exact and safe | Keep the safe guidance, but treat the one-pair gain as diagnostic. Neither role opened the longer manual; both used global and focused help, so put the next shortest-path experiment directly in `suggest add --help` |
| v48 | Put a structured exact-assignment path in focused command help | In a $0.0095 matched pair, v48 used 21 rather than 20 commands and scored 97.500 rather than 97.778, though it used two fewer model turns, finished 16.340 seconds faster, and cost $0.0007 less; both arms were exact and safe | Keep the structured guidance mechanism, not its pre-read instruction. The task requires a final read, and `--quote` plus `--expect` already validates source atomically, so the prescribed preliminary read was redundant |
| v49 | Treat exact text as the source guard instead of prescribing a preliminary read | A $0.0096 pair tied at 97.500, 21 commands, and 23 model turns; v49 was 1.906 seconds faster, both arms were exact and safe, and both still read four times | Keep the correct CLI guidance. The benchmark's generic “inspect the revision” rule is inapplicable to revision-free suggestion creation and masks the fast path; neutralize that benchmark instruction before further product conclusions |
| v50 | Remove the benchmark's unconditional revision-read instruction | The replacement is command-sensitive: use only task-supplied or observed revision/source preconditions, never invent one, and read state only when the chosen command or outcome requires it. All free gates passed. In the corrected $0.0087 pair, v49 improved 98.056→98.333 and 19→18 commands, but took 6.155 seconds longer and cost $0.0011 more | Keep the correction and v49 guidance, but do not promote from one case. Both v48 roles read before writing; neither v49 role did, so the intended mechanism worked. One early-finishing v49 role repeated final verification while waiting for its peer; measure pre-write and post-write reads separately, then test an on-demand convergence primitive |
| v51 | Distinguish unnecessary pre-write reads from legitimate post-write convergence checks | A new non-scoring diagnostic considers each role only through its first `suggest add`: help is allowed, state reads fail. The exact reference passes, while a purpose-built pre-read driver completes safely but fails the diagnostic. Both 206-test suites and both fake-model execution modes pass | Keep as benchmark instrumentation. Use it with command sequence and outcome checks in the next batch or wait experiment; do not turn a legitimate post-write retry into a blanket failure |
| v52 | Add an atomic same-file suggestion batch and compare it under the same forced contention | One bounded JSON call validates and commits 1–256 exact proposals as one annotation revision; all free gates and startup checks passed. In one $0.0088 private Qwen pair, one of two v52 roles used batch and the other used individual adds. v52 improved 97.778→98.056 and 20→19 commands, but took 14.747 seconds longer and cost $0.0014 more; both arms were exact and safe | Keep the safe mechanism, not an efficiency claim. Add non-scoring adoption and post-write-repeat diagnostics, then expose the complete compact batch recipe in the first focused suggestion surface. The batch role's extra help plus repeated list/read erased its three-write saving |
| v53 | Measure batch adoption and repeated post-write verification directly | Three non-scoring checks distinguish any batch use, all-role batch use, and exactly one list plus one source read after each role's final successful write. Regressions cover the old reference, ideal batching, and an early finisher that polls twice; both 206-test suites and both fake execution modes pass | Keep as benchmark instrumentation. Use it to evaluate one compact first-surface batch recipe and, separately, an on-demand known-peer convergence primitive; do not infer either behavior from aggregate command count alone |
| v54 | Teach the atomic batch on the first focused suggestion surface | `suggest add --help` includes the complete bounded stdin schema and executable `suggest batch FILE --items-file -` path. Free gates passed and focused-help startup changed by 0.079 ms median. In one $0.0074 private pair, the old arm batched in one role while the new arm batched in neither: 98.889→98.611 and 16→17 commands, though the new arm was 6.356 seconds faster. Both were exact and safe | Keep the self-contained help because it is correct, but reject the adoption hypothesis. A role that opened the new add-help page still chose four adds; another stopped at parent help. Measure static help targets, then redesign command priority rather than adding more prose |
| v55 | Preserve privacy-safe focused-help targets in trace diagnostics | Trace shapes now distinguish static paths such as `help suggest add` and `help suggest batch` while collapsing unknown topics and retaining no path, identifier, prompt, or output. Reprocessing the v54 traces proved which page each role saw; both 207-test Python suites pass | Keep as benchmark instrumentation. Use it to test a unified multi-item add surface or reordered primary usage, not another longer guidance paragraph |
| v56 | Make atomic multi-item work a primary form of `suggest add` | `suggest add FILE --items-file ...` routes to the existing batch engine, appears first in add help, and is taught on parent help and global examples; `suggest batch` remains an exact alias. In one $0.0081 private pair, v56 improved 96.667→98.611, 24→17 commands, 25→19 model calls, 46.316→37.912 seconds, and $0.0046→$0.0035; both arms were exact and safe | Keep the unified form as a promising candidate, not a promoted result. One of two roles batched and the other still made four adds; measure adoption and repeated verification across fresh cases before claiming general efficiency |
| v57 | Normalize the unified add spelling in privacy-safe trace shapes | The scorer already treated `suggest add --items-file` as a batch, but trace summaries initially rendered its literal verb. Static trace telemetry now reports the semantic `suggest batch`, matching scorer and rendezvous behavior without retaining arguments | Keep as benchmark correctness. Reprocessed v56 evidence now shows one batch role and one four-add role exactly; require this agreement in future candidate diagnostics |
| v58 | Define exact durable-id convergence before adding a wait command | The contention task already gives both collaborators all eight public contribution ids. It now permits one advertised `suggest wait` call for that exact set, retains list as the old-CLI fallback, counts wait as a state read rather than a write, and measures any/all-role adoption without making it a correctness requirement. Privacy-safe traces retain only `suggest wait`, never the ids or timeout | Keep as benchmark instrumentation. Implement only a bounded, on-demand file-local wait for named durable suggestions; never describe it as collaborator presence or general task completion |
| v59 | Replace blind suggestion polling with a bounded durable predicate | `margin suggest wait FILE ID...` watches one selected file only while invoked, succeeds only when all 1–256 named suggestion ids are embedded, and reports bounded state without inferring presence. In one $0.0079 private Qwen pair, both candidate roles used wait; score changed 97.500→98.611, commands 21→17, model calls 23→19, and reported cost $0.0046→$0.0033. Both arms were exact and safe; candidate duration rose 42.335→43.947 seconds and one role still listed after a successful wait. Same-toolchain release medians changed by -0.013 to +0.029 ms across static help paths | Keep as a measured product candidate, not a promoted result. The one case proves discoverability is possible and supports the convergence mechanism; it does not establish population performance, latency improvement, presence, or broader completion |
| v60 | Distinguish missing convergence support from mistrusting a successful wait receipt | A new non-scoring check treats roles without wait as not applicable, allows the required source read, and fails only when a role makes another successful wait/list after its first successful named wait. Diagnostics now recommend making that receipt terminal instead of proposing a wait that already exists | Keep as benchmark correctness. Reprocess future real traces through the refined check, then use a model-free delayed-peer probe before changing CLI wording from one model case |
| v61 | Isolate polling versus a blocking durable predicate without model variance | Twelve paired trials delayed the second known suggestion by 200, 500, or 1,000 ms. The frozen pre-wait arm made 115 measured list calls; the candidate made 12 waits, exactly one per trial. Both arms preserved source, retained exactly both suggestions, and validated their graphs. The schema independently binds the case set and recomputes every call histogram, aggregate, comparison, and pass flag | Keep as causal mechanism evidence, not model-performance evidence. The wait removes polling work; receipt trust remains a separate behavioral question, so refine that contract without claiming presence or broader task completion |
| v62 | Make a successful named-wait receipt explicitly terminal for its observed condition | Success now reports `receiptConclusiveForNamedIDs:true` and `immediateRecheckRequired:false`, says not to list/wait again unless a later file mutation is known, and labels the optional source read as separate from id rechecking. The real add→wait output contract, help/manual copy, bounded projections, both fake Prime paths, and nine-scenario reference all pass. The signed CLI remains 2,842,784 bytes; 500-launch median deltas versus v59 are -0.054 to -0.036 ms | Keep as a protocol-clarity candidate. Do not claim the wording changes model behavior from the earlier one-case trace; test receipt trust on fresh cases only after freezing a matched study |
| v63 | Separate visible generation, hidden reasoning, and provider-wrapper budgets | The first fresh v62 study arm was exact but non-adoptable because Prime reported 2,094 completion tokens, including 1,615 reasoning tokens, against a plan that reserved only 1,800 + 8. The proxy stopped after $0.0014 account-wide movement and the candidate never ran. Alibaba documents `thinking_budget` for Qwen 3.7 but not a 4,000-token Flash default, so controllers freeze 4,000 as the study's conservative reasoning ceiling, inject it, price the complete bound, reject larger caller budgets, and no longer confuse a local budget 429 with provider throttling. Native is 189/189, both Python suites are 217/217, and publication audit is green | Keep as harness safety, not product or model evidence. Start no automatic retry. A new run identity must first prove Prime accepts the frozen Qwen extension; only then may the receipt-trust pair resume |
| v64 | Require a fresh one-request provider-contract receipt before a paid reasoning study | The new probe is dry-run by default and permits one fixed public prompt, one request, zero agent processes, zero retries, and at most $0.00097682 reserved beneath a $0.001 hard cap. It retains only counts, checks, timing, and account-wide wallet movement—never prompt or response content. A passing receipt must match the model, reasoning ceiling, and evidence source; prove one forwarded request, bounded usage, a successful response, and a post-call wallet observation; be at most 24 hours old; and is frozen by digest into every direct, paired, and crossover plan. Fake upstream acceptance/rejection, semantic tampering, staleness, mismatch, and paid-admission tests pass. Both Python suites are 222/222 after adding the two schemas and five contracts; no paid request was made | Keep as a provider-admission safety gate. A successful response shows only that the gateway returned success for a request containing the setting, not that an intermediary preserved it or the provider will enforce it. Continue bounding every study call independently; run the live probe only as a separately reviewed, explicit paid action |
| v65 | Run the admitted receipt-trust pair on a fresh private case | The one-request probe passed: 17 input tokens, 189 completion tokens including 183 reasoning tokens, no retry, no rejected request, no retained text, $0.0001 account-wide debit, and receipt SHA-256 `86948b…`. The fresh two-job plan froze that receipt, six-second request pacing, a $0.025 cap per job, and a $0.05 total cap. Both v59 and v62 jobs completed safely, preserved source, had no invalid commands or infrastructure errors, and trusted one successful named wait per role without rechecking. v59 scored 100 in 11 commands/13 model calls; v62 scored 99.444 in 14 commands/16 calls because one role used four individual adds after opening the batch-teaching help, while its peer batched. The verified pair reported $0.0065 total cost/account-wide debit against $0.012609 proxy-accounted upper bounds | Reject the receipt-wording benefit hypothesis on this case: trust was already perfect in both arms. Do not infer a v62 regression from one pair. Quantify per-role batch teaching, adoption, and receipt trust in the benchmark before changing the CLI or buying a larger sample |
| v66 | Separate suggestion teaching, mechanism adoption, and receipt trust without retaining private content | Trace-shape reports now count, globally and by role, whether focused batch teaching preceded a write, whether the role then used atomic batch or individual additions, whether a named wait was observed, and whether its receipt was trusted or rechecked. Semantic validation proves the teaching/adoption subsets, wait partition, scenario totals, and global totals. Diagnostics attach the same bounded evidence to incomplete-batch findings. Reprocessing v65 produced the intended distinction: v59 was 2/2 taught, 2/2 batched, and 2/2 trusted; v62 was 2/2 taught, 1/2 batched, 1/2 individual, and 2/2 trusted. Both supported Python suites pass 224 tests | Keep this benchmark layer. The evidence rules out missing batch teaching and wait ambiguity in this pair; inspect the interaction cost of expressing a batch before changing copy or buying a larger sample |
| v67 | Let an agent pass its supplied assignment array unchanged to one atomic command | `margin suggest batch FILE` now reads standard input by default and accepts a bare array; the versioned envelope, `--items-file`, and unified-add spelling remain compatible. The first focused add-help usage points to this path, so the benchmark's exact assignment array needs no wrapper or file/stdin flag. The same bounded atomic engine still validates all anchors, writes one revision, retries annotation-only races, rejects source drift, and makes exact replay conclusive. Native 189/189, both Python suites 224/224, nine-scenario reference 100, isolated controls, signed release, and publication audits pass. The signed CLI grew 16 bytes to 2,842,800; suggestion capabilities are 20,303 bytes compact/32,346 pretty. Across 500 counterbalanced samples per arm, new-minus-v62 median startup was -0.004 ms for global help, -0.036 ms for add help, and -0.049 ms for batch help | Keep as the next mechanism candidate. It directly targets measured adoption friction without more prose or startup work. Freeze it against v62 and run one fresh capped suggestion-contention pair; use v66's role metrics to decide whether adoption—not just correctness—improves |
| v68 | Attempt one fresh private v62-versus-v67 suggestion-contention pair | The v62 arm was valid and exact: 97.5, 21 commands, 23 model calls, no invalid commands, 2/2 atomic batches, 2/2 named waits, and one unnecessary post-wait recheck. Its trace-reported and account-wide debit were both $0.0056. The v67 arm then encountered `LIVE_PROXY_UPSTREAM_ERROR` after 18 forwarded calls. Its summary was correctly non-adoptable, the controller made no retry or comparison, and the account-wide wallet moved another $0.0029. The partial candidate trace is infrastructure evidence only. It cannot measure batch adoption or product quality | Preserve the censored attempt and do not retry it in place. The failure revealed that an indeterminate provider request remained outstanding and later requests could continue until another guard stopped them. Harden that budget state before planning a wholly new matched pair |
| v69 | Stop paid forwarding immediately after one indeterminate provider request | Transport failures, oversized responses, malformed success bodies, and non-2xx responses now retain the complete admitted reservation as an uncertain charge, clear the in-flight slot, and latch the loopback proxy closed. Later calls are rejected locally and cannot reach the provider. Reports expose `uncertainRequestCount`; validators bind settled + uncertain + outstanding requests to the forwarded total and classify uncertainty as infrastructure. Direct gate and end-to-end 503 regressions prove exactly one upstream request, zero outstanding reservations, a full conservative charge, and a local stop on the second call. Both supported Python suites pass 227 tests | Keep as benchmark cost and evidence hardening. It changes no Margin CLI or app path. Run the complete free release/privacy gates, then require a new provider probe and new private run identity before any further paid comparison |
| v70 | Recheck the provider contract after uncertainty hardening | One separately admitted request completed with 17 prompt tokens, 181 completion tokens including 175 reasoning tokens, no retry, no rejected request, zero uncertain or outstanding requests, and $0.0001 account-wide wallet movement. The fresh receipt digest `1fc39c9f…` was frozen into the next pair | Keep as admission evidence only. It proves that one request carrying the frozen reasoning setting succeeded; every later request remains independently bounded and may still fail |
| v71 | Measure the bare-array atomic batch on a fresh private pair | Both v62 and v67 completed safely with exact source preservation and zero invalid commands. v67 improved score 97.5→98.333, commands 21→18, model calls 23→20, duration by 17.198 seconds, prompt tokens by 44,394, and trace-reported cost $0.0058→$0.0044. The author used one atomic batch; the reviewer opened only focused single-add and wait help, then made four individual additions. Baseline batched in both roles. Total trace/account movement was $0.0102; the conservative proxy upper sum was $0.019773. Submission `sha256:042a1394…` verifies with seven artifacts and no private content | Keep v67 as promising one-case mechanism evidence, not a promotion. The gain is internally coherent but only 1/20 required matched cases. The role split shows that bare stdin helps when discovered; the next candidate should make the same atomic path natural from `suggest add`, not add more prose or spend on a larger sample yet |
| v72 | Reject publication paths that collide with private controller evidence | The v71 jobs finished, but the initially supplied publication directory was the controller's own redacted-job directory, so finalization failed with a generic read error. No model reran; moving only finalization to a separate publication sibling reproduced and verified the result. The controller now rejects any publication path equal to, inside, or containing its raw, redacted, or frozen-input trees before creating work state, reading the wallet, claiming a paid start, or launching a child. Focused collision and normal pause/resume/replay tests pass | Keep as benchmark reliability and operator clarity. Use a sibling publication directory for new studies. This changes neither Margin nor the agent task surface and requires no paid confirmation |
| v73 | Make no-flag `suggest add` the atomic multi-item path | `margin suggest add FILE` now reads the supplied bare item array from standard input when no single-item selector flag is present; one-item syntax and the `suggest batch` alias remain unchanged. Invalid missing-target calls fail before reading stdin. Semantic telemetry classifies the form as one batch, the fake agent adopts it from focused add help, and both in-process and environment-server suggestion-contention rehearsals pass. Native 189/189, both Python suites 228/228, nine-scenario reference 100, neutral production isolation, audits, signed release, exact replay, all-or-none rejection, and contention regressions pass. The CLI remains 2,842,800 bytes; suggestion capabilities are 20,536 bytes compact and 32,579 pretty. Across 500 counterbalanced launches per path versus v67, median deltas were +0.006 ms global help, -0.042 ms add help, -0.022 ms batch help, and +0.040 ms suggestion capabilities | Keep as the next single-mechanism candidate. It removes the reviewer’s measured verb-switch cost without adding startup work or weakening safety. One capped fresh matched pair would now be informative, but do not extrapolate v71 or buy a larger sample before that pair confirms both-role adoption |
| v74 | Test the same-verb add path on one fresh private case | Both arms completed safely with exact source preservation and zero invalid commands. v73 improved 99.444→99.722, 14→13 commands, 16→15 model calls, duration by 4.387 seconds, prompt tokens by 1,266, and reported cost $0.0034→$0.0033. v67 batched in one role; v73 batched in both, confirming the intended mechanism on this case. Both v73 waits were trusted. Its remaining loss came from one role’s unnecessary pre-write inspect and post-write review, not batch adoption. The verified pair used 31 model calls, $0.0067 trace/account movement, and $0.013419 conservative proxy accounting; submission `sha256:2e41eba…` verifies and both key copies were destroyed | Keep v73 as stronger mechanism evidence, not a promotion: this is 1/20 required new matched cases. Do not scale paid sampling yet. Improve the benchmark’s ability to separate pre-write uncertainty, required source verification, and redundant post-write review; then decide whether the next product change is warranted or the extra calls are stochastic |
| v75 | Separate preliminary reads, required verification, and extra post-write reads | The scorer now permits exactly one successful convergence check and one literal source read after each role’s last successful suggestion write, while independently reporting any additional successful state read. Content-free trace reports add backward-compatible counts for pre-write state reads and extra post-write state reads, globally and per role. Reprocessing the sealed v74 traces reports 0/0 for v67 and 1/1 for v73: the same candidate role inspected before writing and reviewed after its successful wait and required source read. The focused diagnostic is now `extra-postwrite-state-reads` instead of generic interaction efficiency. Older trace and diagnostic reports without the fields still validate. Both supported Python runtimes pass 229 tests; no model call or CLI change was made | Keep as benchmark instrumentation. The single private observation is now measured precisely but remains insufficient product evidence. Replicate it on future matched cases before changing receipts or help, and preserve the required wait/source-read safety checks in any experiment |
| v76 | Stress complete atomic suggestion batches under real process contention | The backward-compatible contention catalog now includes four-item atomic suggestion batches and discloses the item count. Its verifier explicitly reads up to 256 suggestions, so the 32-writer case cannot be truncated by the normal 64-item UX default. A first draft correctly exposed two harness errors: the public release predated the batch command, and the verifier truncated 128 suggestions. The corrected capability-matched run compares the first batch-capable checkpoint with v73 across 2/4/8/16/32 writers and four repetitions. Each arm completed all 248 batches—992 suggestions—in one visible call per batch, with zero visible conflicts, unchanged source, and valid graphs. The complete six-family matrix covers 120 episodes per arm and validates; the prior five-family v45 report still validates unchanged. Both supported Python runtimes pass 231 tests and the complete evidence audit passes | Keep the family and the retained model-free result. It establishes atomic-batch safety and no concurrency regression, not model-quality or speedup. Future product comparisons must use a baseline that implements the operation being measured; feature absence must never be mislabeled as unsafe contention |
| v77 | Define a fair no-exchange floor without assigning impossible work a zero | Final neutral results are decomposed into role-authored creations, prior-parent dependencies, prior-suggestion decisions and source changes, later staged commits, and external non-file state. Exact private role oracles normalize independently creatable roots to their pre-collaboration state and omit structurally impossible replies and transaction facts. The public schema exposes only fixed categories and counts, with `overallScore: null`; it excludes prompts, bodies, paths, actor and fact IDs, and fingerprints. One public-development repetition yields 11 independent, 15 collaboration-dependent, and 3 external slices across the nine frozen scenarios. Parallel shards and specialist audit are fully independent; relay, handoff, decision, staging, directory, and synthesis tasks contain explicit dependencies | Keep as benchmark architecture, not model evidence. The role-specific oracle and non-vacuous aggregation gates are complete. Keep the profile non-runnable until a served, adversarial independent-workspace proof establishes that roles cannot observe one another's transcript, writes, or durable state |
| v78 | Prove no-exchange workspaces are physically and operationally isolated | A model-free preflight separately materializes every role's initial Markdown under mode-0700 roots, confirms distinct device/inode identities and byte-identical sources, and serves each copy through a fresh read-only tool session. Adversarial write, parent-path, absolute-path, and symlink attempts are blocked; transcript canaries and private state remain outside the workspaces; collaboration metadata is absent; and a trusted one-sided mutation cannot affect a peer copy. The complete nine-scenario run passed all checks across 17 distinct role workspaces and 17 served sessions; its 4,935-byte receipt validates. Both supported Python runtimes pass 239 tests. The schema and semantic validator retain only scenario, repetition, counts, booleans, and duration | Keep as an isolation component, not a runnable control or model result. The remaining gate is an integrated profile runner that binds one independent workspace and private oracle to each separate agent process and collects a bounded response without creating a hidden exchange channel |
| v79 | Make provenance-sensitive handoff conflicts actionable without making them automatic | Handoff creation still refuses to silently rebase when its observed root changes. The same temporary failure now states that nothing was written and emits fixed structured fields: operation, `handoffWritten:false`, `automaticRetrySafe:false`, recovery target, `margin context TARGET --json`, `margin handoff list TARGET`, and the never-silently-rebase policy. Focused help, workflow capability projections, and the progressive handoff manual teach the same sequence. The existing stale-revision contract test now verifies every field and unchanged revision; the full 189-test native suite passes. The signed CLI remains 2,842,800 bytes. In the final 500-pair counterbalanced launch check against v73, candidate-minus-baseline medians were +0.002 ms for global help, -0.007 ms for the brief handoff projection, and -0.002 ms for focused handoff-add help; p95 deltas were +0.026 to +0.036 ms—scheduler-scale differences rather than a startup regression | Keep as a low-risk agent recovery improvement. It does not auto-retry, change handoff semantics, or claim better model behavior. Measure whether future agents follow the returned recovery sequence on a fresh conflict before considering a dedicated reauthor command |
| v80 | Measure safe handoff recovery as behavior rather than inferring it from an error string | The content-free private-trace reducer now applies a fixed recovery state machine after each failed `handoff add`: it distinguishes an exact actionable receipt, successful current-context and handoff-list reads after that conflict, a reauthor attempt only after both reads, successful recovery, blind retry, and unresolved conflict. Counts are trace-level globally and by scenario/seat. Semantic validation binds every subset and scenario total; a synthetic three-trace regression covers safe recovery, blind success, unresolved recovery, tamper rejection, and backward compatibility. The emitted report excludes arguments, recovery targets, handoff bodies, actor and contribution IDs, prompts, stdout, stderr, paths, and exact result sizes. The complete local suite passes 240 tests with 21 dependency-gated skips. Reprocessing the retained three-trace v19 handoff pair correctly reports zero applicable conflicts, rather than awarding vacuous recovery credit | Keep as benchmark instrumentation, not agent evidence. Apply it to the next fresh matched handoff-conflict run; do not interpret old runs with no conflict as successful recovery, and do not buy a larger sample until a small pair shows the new receipt is both observed and followed |
| v81 | Make the safe handoff recovery read compact by default | The structured failure, focused help, progressive manual, CLI guide, contract test, and trace recognizer now consistently direct agents to `margin context TARGET --json --brief` before the dedicated handoff review. This changes no mutation or retry semantics. On two tracked large Markdown targets, the existing bounded brief projection reduced agent-visible context from 7,844 to 2,249 bytes and from 9,813 to 2,450 bytes (71–75%) while retaining root orientation; `handoff list` remains the explicit review step. The signed CLI remains 2,842,800 bytes. In 500 counterbalanced launches against v73, candidate-minus-baseline medians were +0.012 ms for global help, +0.004 ms for handoff-add help, and +0.027 ms for the brief handoff capability projection; p95 deltas ranged from -0.043 to +0.017 ms | Keep as the compact recovery contract. Use the v80 trace state machine in the next small matched conflict pair; measure whether both required reads and safe reauthoring improve before changing command count or adding a combined recovery primitive |
| v82 | Prove the handoff recovery measurement against the real CLI, not only synthetic trace shapes | A model-free integration creates a real annotated Markdown file, forces a stale handoff revision through the signed candidate, captures the actual gateway receipt, follows compact context and handoff review, intentionally reauthors the same stable contribution against the observed revision, and feeds those real tool payloads through the private-trace reducer. The reducer reports one applicable and actionable conflict, both reads, one safe attempt, one success, zero blind retries, and zero unresolved conflicts. The original Markdown source remains byte-for-byte logical content, and the redacted report contains none of its private canary | Keep as the local release gate for this metric. It proves contract plumbing and privacy, not that a model will follow the sequence; only the next fresh matched conflict pair can supply that behavioral evidence |

The v41 retry path is never initialized for help or ordinary reads. In a
counterbalanced 100-process final sample, global help measured 5.704 ms median /
7.212 ms p95 for the published v0.4.0 binary and 5.617 ms / 6.456 ms for the
candidate. These are scheduling-scale differences, not a speedup claim; they
show that the concurrency safety path adds no observable startup penalty.

The v34 mechanism pair used one fresh private case and is therefore diagnostic,
not a population estimate. It cost $0.0209 as reported by the model adapter;
its conservative proxy upper bound was $0.1068. The v35 pair reported $0.0266
with a $0.138892 conservative upper bound. An earlier v34 attempt stopped after
one arm because Prime returned a temporary upstream 502; its deterministic
workspace checks happened to pass, but the controller correctly censored the
pair and did not retry. That incident reported $0.014. This continuation's
model-reported total is therefore $0.0615; account-wide wallet movements remain
separate, unattributed observations and are not called experiment spend.

MarginBench itself was hardened in the same loop:

- infrastructure causes survive from the gateway through run, completion, and
  controller receipts, and censored comparisons name the exact failing layer;
- paid requests use an inter-job cooldown and uncertain provider attempts are
  never silently retried;
- privacy-safe trace shapes now include command sequences, coarse response-size
  buckets, unanswered calls, and path-to-first-write buckets without retaining
  prompts, arguments, paths, identifiers, or document content;
- paired publications now produce trace-shape evidence for both trial arms.
  Each shape is linked to its candidate identity, because a binary digest alone
  cannot distinguish two settings bundles that intentionally share one binary;
- multi-candidate diagnosis uses only the selected candidate's trace evidence,
  so reversing operational order cannot change which behavior is diagnosed;
- a role that has already produced the complete durable outcome is no longer
  mislabeled as a product-facing budget failure merely because its final tool
  call consumed the last turn before a closing sentence;
- plain-text CLI usage failures now receive the stable `USAGE` class instead of
  falling into an unclassified bucket.

At this checkpoint the native suite passes 177 tests. Both the system and Prime
Python runtimes pass 198 MarginBench tests; the full nine-scenario reference
run scores 100 with no model call, and the neutral control and publication
audits pass. The compact-context regression is included in those final counts.

A final load-sensitive audit found one benchmark race rather than a product
failure. In `concurrent_review`, the ideal two-writer reference path uses four
calls. A real shared-state collision correctly adds one failed write and the
prescribed reread before retrying, for six calls. The old five-call efficiency
target therefore made the exact safe recovery path score 99.230769 under CPU
contention even though every outcome and safety check passed. The target is now
six, a direct regression constructs the collision, and the complete Prime
runtime suite passes while the system suite runs concurrently. This changes no
document outcome, safety rule, or maximum command budget; it only stops charging
an agent for the benchmark's own required recovery protocol.

The wide-directory measurement is now a first-class model-free command rather
than an ad hoc fixture. It creates deterministic, byte-identical workspaces,
normalizes generated IDs and timestamps, validates every embedded comment
envelope, alternates candidate order, verifies source preservation, and emits a
schema-backed report. The retained development report is
`Evals/marginbench/results/wide-directory/v37-model-free.json`. That probe also
found that early-stop discovery could report one observed omitted file as if it
were an exact total. The CLI now labels `omittedFileCount` as a lower bound when
it intentionally avoids a full directory walk. The report's pass condition
also requires nonempty actionable files, work items, guidance, action paths,
roots, and revisions; deterministic empty output cannot pass.

Concurrent contention is now equally reproducible. `concurrency-probe` starts
the frozen baseline and candidate at the same barrier for each episode,
counterbalances which arm is submitted first, and emits no paths, bodies,
identifiers, or event traces. Its retained 1,000-pair report is
`Evals/marginbench/results/concurrency/v41-model-free.json` (SHA-256
`a5bf26712590063d8851f7babe7930e40b3b68d1918f4504d7f67084cb644fdb`).
The baseline had 719 agent-visible collision/recovery episodes (`281 × 4`
calls, `719 × 6`), while v41 had none
(`1,000 × 4` calls). Both arms scored 100, passed safety, and
preserved every source byte. The report passes its v1 schema and semantic
consistency checks. Both arms must be correct, safe, source-preserving, and free
of invalid calls; only baseline collisions remain descriptive rather than a
pass requirement, so scheduler luck cannot invalidate the mechanism gate.

The portable Linux gate passes 124 core and CLI tests across 19 suites. Each
test runs in its own XCTest process with a strict timeout. Live LLDB inspection
of the intermittent stalls found the exact open swift-corelibs XCTest teardown
deadlock: `ppoll`, Foundation's run loop, XCTest expectation waiting,
`performTearDownSequence`, and `invokeTest`, with no active Margin frame. The
diagnostic runner freezes a timeout and retries at most twice only when that
whole framework stack is present. Assertion failures, crashes, debugger
failures, product stacks, and unclassified timeouts fail immediately. A
200-process stress sample recovered four exact framework deadlocks; a forced
0.001-second timeout was correctly rejected as unclassified. One complete gate
then passed with one proven recovery, followed by three consecutive clean
124-test runs with zero recoveries. The policy contains an upstream framework
defect without masking a product failure. See
[swift-corelibs-xctest #504](https://github.com/swiftlang/swift-corelibs-xctest/issues/504).
A Linux archive rebuild was attempted separately, but Docker Hub
stalled while resolving its build frontend before compilation began; that is
recorded as packaging infrastructure rather than a product result.

Startup remains flat. In one counterbalanced 100-process sample, ordinary help
measured 5.654 ms median for the published v0.4.0 binary and 5.674 ms for v36;
context help measured 5.648 and 5.701 ms. A real brief-context operation measured
17.832 ms median for v35 and 17.892 ms for v36. These sub-millisecond differences
are scheduling noise, not a speed claim, and show no material regression.

That next experiment now exists as the opt-in `wide_directory_triage` scenario.
It has 16 Markdown files, 64 distractor threads, one uniquely typed question in
the omitted portion, and an exact reply-and-resolve outcome. The model-free
reference proves the intended route: brief context, filtered brief inbox,
targeted thread read, atomic reply-and-resolve, verification, and validation.
It remains outside the stable nine-scenario default so historical studies do
not silently change. A future paid plan should start with one cheap fresh
matched case and expand only if both arms actually exercise the intended route.
Directional product language still requires at least 20 valid matched cases
under the frozen promotion rule.

The CLI's own progressive manual now teaches that same route. It no longer
adds `--max-files 16` to brief context or requests a full-cursor inbox by
default. The benchmark also checks sequence, not just command presence:
successful context must precede the filtered inbox before the first mutation.

The final local candidate binary is 2,776,448 bytes with SHA-256
`883ed7e4e1a11fbb035a619c96ffb949793635c8493253ea005512ecc0533902`.
The combined app-and-CLI zip is 3,656,870 bytes with SHA-256
`aa255580813d3da6aa8d1d98c6ddbdd98fac43a847352d9e07c11c7fa6b7c6a0`;
the installer is 3,644,806 bytes with SHA-256
`8c53681bbcd52075f54d2ff43cb845011c449f9259e957d463673cdabe2f4847`.
Both checksum files and zip integrity verify. The app and CLI are ad-hoc signed;
the installer remains unsigned and this development candidate was not
published over the v0.4.0 release. Repackaging can change archive-container
checksums and the unsigned installer metadata even when the executable is
byte-identical, so benchmark candidate identity is always the executable digest
(`883ed7…`), never a zip or installer digest.

## Next research queue

1. Extend the model-free contention matrix to suggestions, handoffs, and more
   than two writers before generalizing the new retry behavior. Each operation
   needs its own proof of what may be safely rebased; “same Markdown” alone is
   not automatically sufficient for every collaboration meaning.
2. Buy a real-model matched concurrency case only to answer an agent-behavior
   question: whether removing visible recovery changes completion, command
   choice, tokens, or latency. The 1,000-pair mechanism result already answers
   the storage/CLI question without further spend.
3. Add fresh held-out wide-directory shapes and vary relevant-work density,
   nesting, and document size while preserving historical scenario versions.
   Promote compact discovery only if agents recover omitted work as reliably as
   they do on the full view.
4. Restore the digest-pinned Linux binary inputs required by
   `make marginbench-package`, then rebuild and inspect the portable wheel. The
   app-and-CLI macOS zip/pkg are green; the benchmark wheel correctly refuses to
   package while either Linux architecture artifact is absent.
5. Keep the current v0.4.0 public release untouched until a later candidate
   earns the frozen promotion threshold and passes the full release audit.
