# MarginBench crossover results

Date: 2026-08-19. Status: public development evidence, not a leaderboard.

## Targeted stage-recovery candidate check

After the nine-family study, the recovery guidance candidate was tested against
the frozen v17 baseline with the same public staged-multi-file case and the same
Qwen 3.7 Flash settings. The first candidate attempt completed the task but
received a provider rate-limit error, so it was retained privately as an
infrastructure incident and excluded from the comparison. A new two-cell plan
with a ten-second request interval then ran once, with no retry.

The baseline scored 25: it preserved the Markdown source but did not complete a
safe workspace transaction, used 14 commands, and made five invalid calls. The
recovery candidate scored 95.625: it completed the atomic change safely,
preserved the source, used 13 commands, and made one invalid call. It was about
9.3 seconds faster. The two accepted cells used 29 model calls and cost $0.0055
in total.

This is strong evidence for the specific recovery mechanism, not a promotion
result. It is one public development case against a required minimum of 20, so
the comparison remains non-promotable. The surviving candidate mistake was
also useful: from inside the workspace, the reviewer first called `stage list`
without repeating the root. Margin now treats that as the natural form,
discovers the current workspace, and still accepts an explicit root. That last
change happened after the frozen candidate and is not credited to its score.

The complete redacted bundle is
`Evals/marginbench/results/candidate-studies/v20-stage-recovery-public-r0/`.
Its submission ID is
`sha256:5b95234b52339fad222c36b6bdbb5393d6d8f2d34860514f4a61bc39788568e0`.
The bundle contains no prompts, document text, paths, credentials, raw traces,
or holdout key and passes `marginbench submission verify`.

A matched handoff check was deliberately less exciting: both the old and new
CLI scored 100. That clean tie matters because it shows that an earlier
old-versus-new contrast on the handoff case was ordinary model variation, not
proof that the interface change caused the difference.

## Complete paced nine-family real-model breadth study

The first complete breadth study ran all nine public challenge families once
with fresh role-separated agents and once with one continuing agent. All 18
cells used Qwen 3.7 Flash at temperature zero under one frozen contract. A
six-second minimum interval between provider requests eliminated the 429 that
stopped the preceding attempt. Every pair was safe, every source file was
preserved, and the whole study cost $0.0462 across 191 model calls.

| Challenge | Fresh roles | Continuing agent | What the case exposed |
| --- | ---: | ---: | --- |
| Suggestion decision | 98.57 | 94.11 | Fresh review was cleaner |
| Distributed synthesis | 100 | 100 | Both transferred all required facts |
| Directory handoff | 96.25 | 100 | Fresh reviewer recovered from one wrong option |
| Human-agent relay | 100 | 100 | No useful topology difference |
| Independent shards | 97 | 98 | Small coordination cost erased the expected lead |
| Specialist audit | 100 | 96.25 | Fresh specialist completed the independent check |
| Agent-agent handoff | 66.25 | 95.54 | Fresh author exhausted its response budget before acting |
| Concurrent review | 96.67 | 98.33 | Both recovered safely from the injected stale write |
| Staged multi-file change | 57.5 | 79.38 | Both found staging too indirect under the turn limit |

The continuing agent led four cases, fresh roles led two, and three were
inconclusive. Fresh roles averaged 5.485 score points lower, with a paired 95%
interval from -13.568 to 1.001. They averaged 0.56 fewer model calls, 22,754
fewer prompt tokens, $0.000644 lower cost, and 0.98 seconds less elapsed time.
With only nine pairs against a predeclared minimum of 20, the report correctly
says `insufficient-data`; none of those averages supports a population claim.

The useful result is the failure map. Collaboration helped when a fresh
specialist had a genuinely different job and compact durable evidence. It did
not help when the work was serial, symmetric, or depended heavily on retained
working state. The largest fresh-role failure happened before the author made
any tool call, so it was a cold-start/model-output-limit failure rather than
lost Margin data. The hardest shared problem was multi-file staging: atomicity
kept both weak executions safe, but review and recovery required too much
rediscovery.

Those observations produced concrete post-study changes: atomic reply and
resolve through `comments add --parent ... --resolve`; exact guidance when an
agent confuses `comments suggest` with top-level `suggest`; cursor-based
guidance for handoffs; and executable next actions after stage create, list,
show, refresh, and stale submit. These changes were made after the frozen v19
candidate and therefore are not credited to its scores.

The independently reproducible report is
`Evals/marginbench/results/crossover/v19/crossover-report.json` at SHA-256
`7cfdfcc8b070be81c2ce0ccf7ecfed0244858dca6ce0ea80f7ab4c51903b1e41`.
Its complete redacted bundle passes `marginbench audit-crossover`. The separate
content-free trace-shape report is
`Evals/marginbench/results/crossover/v19-trace-shapes.json` at SHA-256
`a8023c002ba3aaad0b5c7f1ff38f437ffa11c981db23d9fb4672e4eb348a43c3`.
It retains counts and error classes, but no prompts, document text, paths,
identifiers, arguments, output streams, or credentials.

## Actionable context and machine-readable manual calibration

Two one-repetition public-development crossovers were run on 2026-08-19 with
`qwen/qwen3.7-flash`. Both used the same two frozen cases, temperature zero,
identical logical work and limits, the prescribed counterbalanced topology
order, a $0.03 live cap per cell, and no automatic retries. These are mechanism
probes, not estimates of general agent performance.

Candidate `margin-0.3.2-actionable-context-v15` added exact per-file paths and
annotation revisions to directory context. Its four safe cells cost $0.0064.
The independent-shards scores were 91.25 continuing and 93.25 role-separated;
the specialist-audit scores were 70 and 100. Role separation led descriptively
by 16 points on average and had a 1.385 geometric-mean speed ratio, but the
two-pair score interval was 2 to 30 and the report correctly remained
`insufficient-data`. Content-free traces found three malformed manual lookups
and one unsupported `finding` contribution label.

Candidate `margin-0.3.2-machine-readable-manual-v16` added bounded JSON output
to `margin man` and accepted `finding` as an alias for the canonical issue kind.
Its four safe cells cost $0.0068. Exact results were:

| Challenge | Continuing agent | Role-separated | Descriptive result |
| --- | --- | --- | --- |
| Independent parallel shards | 98; 33.49 s; 8 commands; 0 invalid; $0.0025 | 93.25; 21.12 s; 9 commands; 1 invalid; $0.0015 | Continuing on this case |
| Specialist security audit | 73.75; 41.29 s; 3 commands; 0 invalid; $0.0012 | 100; 40.75 s; 6 commands; 0 invalid; $0.0016 | Role-separated on this case |

Across these two pairs, role separation led descriptively by 10.75 points on
average and had a 1.268 geometric-mean speed ratio. The score interval was
-4.75 to 26.25 and the speed interval was 1.013 to 1.586; with only two pairs,
the frozen conclusion is still `insufficient-data`. Both shapes preserved all
source and workspace boundaries.

The targeted manual and kind errors disappeared. The only invalid v16 command
was a safe compare-and-swap conflict: one agent read revision zero, guessed one
in its first write, then retried successfully with zero. In the specialist
case, the continuing agent stopped after the first contribution and omitted the
independent audit; the fresh specialist completed it exactly. This is useful
topology evidence rather than a CLI syntax defect. It reinforces the benchmark's
purpose: collaboration helps some task structures, while continuity helps or is
cheaper in others.

The validated v15 and v16 reports are respectively
`Evals/marginbench/results/crossover/v15/crossover-report.json`
(SHA-256 `68a7afe0d4642aaecea66f07a580770c1f5d9f6a0a8f01ed605a4fef2aadc9fa`)
and `Evals/marginbench/results/crossover/v16/crossover-report.json`
(SHA-256 `a035e085575a58650e47382b36e4a7a2358accc1b4a8f747ce41168343d83475`).
Raw conversations remain private and ignored; the published runs, summaries,
plans, candidates, and reports are bounded and independently schema-validated.

A final one-case mechanism probe used
`margin-0.3.2-structured-manual-v17`. Manual JSON now carries the relevant
typed command contracts and explicit next queries, while context labels its
annotation revision as the observed pre-write value that must be copied exactly
(including zero). On the same independent-shards case, role separation scored
100 in 19.93 seconds with six commands, zero invalid commands, eight model
calls, and $0.0014 cost. Continuing scored 98 in 31.07 seconds with eight
commands, zero invalid commands, ten calls, and $0.0020 cost. The exact
revision-guessing failure disappeared, as did all malformed help and kind
errors. Both runs were safe and source-preserving; neither was retried.

This $0.0034 probe is consistent with the intended mechanism, but it is one
stochastic repeat of a public development case and cannot isolate candidate
causality. Its frozen conclusion remains `insufficient-data`. The validated
report is
`Evals/marginbench/results/crossover/v17/crossover-report.json`
at SHA-256
`f3401b68135aac4ab0d0baa726e43aa0e46998283602796f74baccc4857f9d66`.

The v15, v16, and v17 evidence bundles are tracked under
`Evals/marginbench/results/crossover/`. Each now passes the same local
`marginbench audit-crossover` gate, which validates every JSON artifact, checks
candidate and plan bindings, matches run/summary cells, requires paired
topology coverage, and reproduces the aggregate report. The audit reads no raw
trace and rejects any unexpected file or symlink.

## First four-family real-model slice

On 2026-08-19, candidate `margin-0.3.2-phase-aware-errors-v14` ran one
public-development pair in each of four deliberately different families using
`qwen/qwen3.7-flash`. Each case followed its frozen `profileOrder`; every cell
was a separate validated run with no retry, a three-cent live cap, identical
sampling and role budgets, and the same Margin binary SHA-256
`7fd5d72d22dcdf02efab57585d87ae77fda208516be91211996ef6637e603912`.

All eight cells preserved source, remained inside the workspace, and produced
valid documents. The full combined report is
`Evals/marginbench/runs/real-breadth-public-v14/crossover-report.json`; its
validated SHA-256 is
`dcd6b7c2eaafb1fdf49bd32ed9825e04e7028f8ebfeae96d8113cbe48c7f3501`.

| Challenge | Role-separated | Continuing agent | Descriptive result |
| --- | --- | --- | --- |
| Serial handoff negative control | 100; 47.54 s; 7 commands; 0 invalid; $0.0019 | 91.79; 66.47 s; 11 commands; 4 invalid; $0.0038 | Role-separated on this case |
| Distributed synthesis | 100; 39.37 s; 8 commands; 0 invalid; $0.0019 | 100; 44.15 s; 9 commands; 0 invalid; $0.0029 | Inconclusive |
| Specialist security audit | 96.25; 59.82 s; 9 commands; 2 invalid; $0.0021 | 100; 47.55 s; 6 commands; 0 invalid; $0.0017 | Continuing on this case |
| Independent parallel shards | 94.25; 25.01 s; 8 commands; 2 invalid; $0.0014 | 90.25; 45.75 s; 12 commands; 3 invalid; $0.0021 | Role-separated on this case |

Across the four pairs, role separation averaged 2.116 points higher, used 1.5
fewer commands and model calls, made 0.75 fewer invalid commands, cost $0.0008
less per case, and had a 1.229 geometric-mean speed ratio. The paired score
interval was -1.875 to 6.161 and the speed-ratio interval was 0.915 to 1.619.
The sample is therefore explicitly `insufficient-data`: it is a useful map of
mechanisms, not a directional claim. Total observed spend was $0.0178 against a
$0.24 absolute combined cap; the wallet ended at $199.4263.

The shape matters more than the mean. Fresh contexts reduced phase carry-over
and command count in the serial and parallel cases. Both approaches recovered
all distributed facts. A continuing context performed the specialist audit
more cleanly than the fresh pair, showing that role labels alone do not create
independent-review value. The benchmark should keep measuring both continuity
benefit and phase interference rather than treating either topology as a
default winner.

Privacy-safe command signatures found three general interface problems without
retaining paths, IDs, prompts, or document text: agents tried multiword manual
lookups, guessed `comments` as a capability workflow name, and shortened a
root-relative file path to its basename. A generic context template also used
revision zero even when a selected document had existing annotation state.
Those observations motivated the next interface candidate; they do not alter
the frozen v14 scores.

Earlier GPT-5.4-mini calibration cells remain development evidence only. V8
exposed literal-template copying in a fresh specialist reviewer. V11 fixed that
case but both topologies omitted the separate resolution step in distributed
synthesis. V12 added atomic reply-and-resolve but showed that a feature has no
value when agents cannot discover it. V13 made inbox actions executable: the
fresh reviewer reached 100, while the continuing agent carried a handoff-only
`--request-id` into the reply phase and scored 70. These successive failures
led to atomic reply closure, actionable inbox paths, phase-specific recovery
errors, and content-free command-signature diagnostics. Runs with provider or
budget infrastructure failure are retained as incidents and excluded from
comparisons.

This run does **not** measure model intelligence. A deterministic reference
policy performed every task perfectly under both collaboration shapes. The run
measures whether the benchmark, real Margin CLI, concurrency, scoring, pairing,
and analysis behave as designed, and establishes the local orchestration cost
before paid model work.

## Frozen run

- Machine: Apple M1 Max, arm64, macOS 26.2 (25C56).
- Cases: nine challenge families, 20 keyed repetitions each, 180 matched pairs.
- Executions: 360 complete episodes, once role-separated and once continuing.
- Order: 10 role-separated-first and 10 continuing-first cases inside every
  family.
- Margin SHA-256: `c220c0d61de8d523a2d55e1226693acda7ee909e2d518cc25572737965d2c57e`.
- Challenge catalog SHA-256: `4c6b8e76e5a8cfc2c5d953814093540f2e4d8cb787b922f6792b98ba8ada1e1f`.
- Crossover plan SHA-256: `f930059d49e87bfeb8c54518c5aced4ad56ca8ec3fdec2b4f7b2bef4805e3ab0`.
- Experiment contract SHA-256: `a55293bfe6d01122375bf5e7327ef78a503ca704424f3bedd9456d0ea99a3f27`.
- Validated primary report: 555,449 bytes; SHA-256
  `a8ca57f10c87f4bee40fecf6cd5f68feeb02622e761a745c101caeab913101bf`.
- End-to-end local runtime: 58.707 seconds for the primary block.
- Paid inference: none.

The exact command used was:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Evals/marginbench \
  python3 -m marginbench.cli crossover-reference \
  --margin-bin build/margin --repetitions 20
```

## Results

Both shapes scored 100 on all 180 cases. Every source was preserved, every
document remained valid, and neither side had a failed outcome check or invalid
command. One concurrent-review case needed the role-separated policy's explicit
conflict recovery, adding two commands; all other command counts matched.
Because this policy does not call a model, call, token, and model-cost
differences are zero.

Elapsed-time ratio is continuing-agent time divided by role-separated time. A
value above one means role separation was faster.

| Challenge family | Pairs | Ratio | Paired 95% interval | Frozen conclusion |
| --- | ---: | ---: | ---: | --- |
| Atomic multi-file change | 20 | 1.011 | 0.992–1.031 | Inconclusive |
| Independent parallel shards | 20 | **1.851** | **1.795–1.904** | **Role-separated** |
| Distributed directory work | 20 | 0.994 | 0.969–1.021 | Inconclusive |
| Human boundary | 20 | 0.989 | 0.953–1.025 | Inconclusive |
| Necessary information transfer | 20 | 1.033 | 0.991–1.095 | Inconclusive |
| Serial handoff negative control | 20 | 0.969 | 0.916–1.007 | Inconclusive |
| Parallel shared-state review | 20 | 1.142 | 1.088–1.193 | Inconclusive |
| Suggestion review and decision | 20 | 1.006 | 0.981–1.030 | Inconclusive |
| Specialist independent review | 20 | 1.009 | 0.988–1.034 | Inconclusive |

Across all 180 pairs, the geometric mean ratio was 1.088 (95% interval
1.057–1.123), below the predeclared 1.20 meaningful-effect threshold, so the
overall result is inconclusive. That aggregate is context only; the benchmark
does not use it as a collaboration score.

The demand slices independently recover the clean mechanical result:

- maximum parallelism: 1.454×, interval 1.346–1.565, role-separated;
- low specialization: 1.279×, interval 1.191–1.378, inconclusive because its
  interval does not clear 1.20;
- zero coupling: 1.851×, interval 1.795–1.904, role-separated;
- low continuity: 1.454×, interval 1.346–1.565, role-separated; and
- other demand cells: no directional conclusion under the frozen rule.

The low-continuity and low-specialization slices are positive because they
contain the clean parallel case. That is correlation, not evidence that either
property causes a team advantage. The design document explicitly treats axis
slices as a map, not a causal regression.

## Execution-block sensitivity

The complete 180-pair run was repeated in three fresh local blocks after the
schedule began interleaving challenge families. This is not a substitute for a
multi-machine model study, but it exposes machine-load sensitivity that a
within-block bootstrap cannot see.

| Measure | Block 1 | Block 2 | Block 3 |
| --- | ---: | ---: | ---: |
| Overall ratio | 1.088 | 1.089 | 1.103 |
| Independent parallel shards | **1.851** | **1.950** | **1.929** |
| Parallel shared-state review | 1.142 | 1.164 | 1.165 |
| Serial handoff negative control | 0.969 | 0.996 | 1.065 |

Independent shards were role-separated in every block; shared-state review and
the serial negative control were inconclusive in every block. Blocks two and
three took 62.051 and 63.539 seconds. Their validated report SHA-256 values are
`958994f71a7f80af931d0893038a2bb8d5553e74ca603a80ced1ef50b290447c`
and `4a6db464bcf4a0609e829f70294f4245adbdfec538a6da5bbc6c9f6e3f3bfa80`.

## What this establishes—and what it does not

The benchmark can distinguish a task with real simultaneous work from serial
or tightly coordinated work without inventing a quality tradeoff. It also
shows why the earlier serial handoff was the wrong place to expect a team win:
with deterministic work, it is essentially tied and provides no parallel
benefit.

The model-free policy cannot measure fresh-review quality, bias reduction,
specialist judgment, information loss, token duplication, or model recovery.
Those are precisely the effects for the first small real-model crossover. The
next paid slice should therefore include the serial negative control,
independent parallel shards, specialist audit, and distributed synthesis, with
the same model and fixed limits on both sides.

## Other gates completed

- All nine deterministic reference scenarios score 100.
- The Prime Verifiers fake-model rehearsal passes all nine cases both in
  process and across the separate environment-server boundary: 17
  role-separated traces and 9 continuing traces, 88 tool interactions per
  shape, no rejected requests, and no paid inference.
- A fresh private key also passes all nine cases for both topologies across the
  environment-server boundary; only its one-way identifier was emitted and the
  key was overwritten and removed immediately afterward.
- The challenge catalog, crossover plan, and crossover report each pass their
  bundled JSON Schema and semantic validation.
- A known synthetic 2× speed crossover is recovered as role-separated only at
  20 pairs; the same effect at three pairs remains `insufficient-data`.
- A noisy three-point quality lead remains inconclusive when its uncertainty
  interval does not clear the frozen two-point meaningful-effect threshold.
- Mismatched candidate, build, fingerprint, case coverage, duplicate case, and
  infrastructure-error evidence fail closed. The analyzer also requires the
  same model, limits, retry policy, cost policy, benchmark implementation, and
  case partition on both sides.
