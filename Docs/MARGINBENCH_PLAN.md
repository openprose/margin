# MarginBench build plan

Last updated: 2026-08-17 21:25 ET

MarginBench is the working name for a portable, execution-scored benchmark for
human-to-agent and agent-to-agent collaboration over Markdown workspaces. The
benchmark core belongs to Margin, not to any model provider. Prime Intellect is
the first hosted adapter, evaluation venue, and possible training backend.

This document is the live checklist for the build phase ending at 09:00 ET on
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

Available Prime Intellect credit: **$200.00**.

| Gate | Maximum cumulative spend | Purpose | Status |
| --- | ---: | --- | --- |
| 0 | $0 | Install, login, local tests, container builds, dry runs | In progress |
| 1 | $2 | One tiny end-to-end hosted smoke test | Not started |
| 2 | $15 | Cheap-model calibration on a small public-development slice | Not started |
| 3 | $50 | Paired comparisons of promising CLI/manual variants | Not started |
| 4 | $120 | Broader model/team matrix only after stable signal | Not started |
| Reserve | $80 | Held for follow-up, failures, and a meaningful final run | Untouched |

Rules:

1. No paid run before all local oracles pass and the exact proposed run is
   emitted by a no-model preflight.
2. Every paid command has a hard process, turn, token, timeout, and dollar cap.
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
- [ ] Install the official Prime CLI and verify account access without spending
  credits.
- [ ] Record exact local tool versions and a redacted authentication check.

### 2. Make the Margin engine portable

- [ ] Separate the AppKit application product from the platform-neutral core and
  CLI products in the package manifest.
- [ ] Replace Darwin-only imports and file primitives with audited Darwin/Linux
  implementations behind a small compatibility layer.
- [ ] Preserve locks, atomic replacement, permissions, crash recovery, and
  embedded-comment behavior on both platforms.
- [ ] Build and run the core/CLI tests in a Linux container.
- [ ] Re-run all macOS tests, package checks, and startup measurements; reject a
  material regression.

### 3. Build the provider-independent benchmark core

- [ ] Define versioned task, role, event, tool-policy, trace, and score schemas.
- [ ] Generate deterministic, secret-seeded Markdown workspace episodes.
- [ ] Support sequential roles, concurrent roles, scripted human events,
  external edits, stale state, interruption, and retry.
- [ ] Place a strict Margin gateway between agents and the shared workspace.
- [ ] Score exact outcomes, source preservation, all-or-none transactions,
  attribution, recovery, calls, tokens, latency, human attention, and cost.
- [ ] Add single-agent, no-collaboration, and unconstrained-shell controls.
- [ ] Add local fake-agent and adversarial tests with no paid model calls.

### 4. Add the Prime Verifiers adapter

- [ ] Package a Verifiers v1 environment with named role agents and one shared
  per-episode Margin workspace/gateway.
- [ ] Keep the benchmark's task generator and scorer provider-independent.
- [ ] Support local Docker execution first, then Prime-managed runtime execution.
- [ ] Verify concurrent roles cannot access hidden fixtures, credentials,
  scorer state, ambient tools, or one another's private briefs.
- [ ] Produce a Hub-ready package manifest and reproducible setup instructions.

### 5. Establish the hill-climbing loop

- [ ] Freeze a baseline Margin binary/manual/settings bundle by digest.
- [ ] Express CLI/manual/default changes as named candidates.
- [ ] Compare candidates on identical seeded episodes with paired ordering and
  repeated trials.
- [ ] Require safety/integrity parity and statistically meaningful improvement
  before promotion.
- [ ] Keep prompt optimization, CLI optimization, model comparison, and team
  orchestration as separate benchmark tracks.
- [ ] Store redacted run summaries and a machine-readable experiment ledger.

### 6. De-risk with staged Prime runs

- [ ] Run no-cost install/auth/runtime/model discovery.
- [ ] Run one cheapest useful hosted smoke test (Gate 1).
- [ ] Run a small cheap-model calibration only if the smoke is valid (Gate 2).
- [ ] Hill-climb at least one bounded CLI/manual candidate pair if calibration
  shows non-ceiling behavior.
- [ ] Stop on infrastructure ambiguity, vacuous scoring, or safety leakage and
  repair locally before spending again.

### 7. Publishable benchmark foundation

- [ ] Use the distinct working name **MarginBench**; avoid the existing
  “CollabBench” name collision.
- [ ] Document public development tasks versus private, rotating test tasks.
- [ ] Define four result tracks: model, interface, team, and open systems.
- [ ] Add explicit code/data licensing recommendations and contamination policy.
- [ ] Draft a benchmark card covering scope, limits, metrics, reproducibility,
  security, and leaderboard submission rules.

## Acceptance gates for 09:00 ET

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

## Decisions still to earn with evidence

- Whether the first public release should live inside this repository or in a
  standalone `marginbench` repository once the schemas stabilize.
- Whether concurrent agents should share one container or use separate
  containers connected to a per-episode Margin gateway. The secure default is
  separate agent runtimes plus one narrow shared gateway.
- Which cheap Prime-hosted model gives enough failure diversity for economical
  interface hill-climbing before using stronger models.
- How much of the $200 produces statistically useful evidence after measuring a
  real episode's token and runtime cost.
