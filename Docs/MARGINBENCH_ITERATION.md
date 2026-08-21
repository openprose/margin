# MarginBench iteration loop

Status: active operating procedure, 2026-08-20.

This document defines how Margin and MarginBench improve without confusing a
better tool with an easier test, a luckier model sample, or a repaired runner.

## One cycle

1. **Name one mechanism.** State the expected failure, the surface allowed to
   change, and the measures that should move. Keep the model, cases, topology,
   sampling, budgets, scorer, and safety policy fixed.
2. **Freeze the candidate.** Bind the Margin binary, manual, tool gateway,
   benchmark implementation, and settings by digest. Never change these inside
   a matched pair or reinterpret an earlier score under new rules. A shared
   episode ID is not enough: the published pair must independently match the
   model, temperature, token and turn limits, topology, task build, retry rule,
   and admission budget. Missing fields are reported as insufficient metadata,
   never assumed equal.
3. **Run free gates.** Require all Swift and Python contracts, the nine-scenario
   reference score of 100, both isolated environment-server rehearsals, schema
   validation, source preservation, and launch/startup checks.
4. **Buy the smallest useful observation.** Start with one public case on an
   inexpensive model. Cap every provider request and the complete run before
   authentication. Do not retry automatically.
5. **Classify before fixing.** A failure belongs to exactly one primary layer:
   product interface, benchmark task, scorer, model behavior, orchestration,
   provider infrastructure, or safety boundary. Infrastructure failures are
   incidents, never task scores.
   If the paid model work completed but publication failed, validate and
   cross-check the immutable `generated-summary.json` and `generated-run.json`
   checkpoints, then use `marginbench promote-checkpoint`; never buy the same
   model work again merely to repair bookkeeping.
6. **Use content-free diagnostics first.** Compare command names, option names,
   error codes, sequence shape, counts, timing, usage, and stop conditions.
   Inspect a private raw trace only when that evidence cannot distinguish the
   cause; never publish it.
7. **Change one layer.** Add a regression that reproduces the mechanism, make
   the smallest general correction, and repeat every free gate.
8. **Rerun the matched public case.** Treat the result as development evidence.
   If the target measure improves without a safety, correctness, latency, or
   cost regression, test a fresh generated case.
9. **Confirm privately only after stability.** Use rotating, mode-0600 keys and
   enough matched cases for the predeclared claim threshold. Public tuning
   never promotes a candidate by itself.
10. **Publish the whole shape.** Report quality, safety, time, tokens, cost,
    command count, invalid commands, and recovery separately. Audit the redacted
    bundle as one unit and reproduce its aggregate report from its published
    cells. A single weighted collaboration score is not a release decision.

## Order-neutral evidence

Counterbalancing is useful only if the evidence path is also neutral to which
arm happened to run first. Publish the same privacy-safe trace shape for both
arms, and bind each shape to its candidate identity. A binary digest is useful
corroboration but is not sufficient: two candidates may deliberately share one
binary while changing only the manual or settings. Diagnostics may use an
unlinked historical shape only when exactly one candidate is present; a
multi-candidate report must fail closed rather than guess.

The report may include both arms' shapes, but candidate-specific findings must
use only the selected candidate's evidence. Reversing the labels or operational
order must not change the behavior attributed to a candidate.

## Completion versus conversational closure

Separate durable task completion from a polite final sentence. If all required
work, workflow, recovery, safety, and source checks pass with a full outcome,
an answered final tool call at the turn ceiling is not a CLI budget defect. It
may still be relevant to harness UX or cost, but it must not outrank a real
product opportunity. A turn-limit stop remains a product-facing finding when
the durable outcome, required workflow, valid command use, or required recovery
is incomplete.

## Response-size evidence

Measure the bytes the agent actually receives, including its tool adapter, in
coarse privacy-safe buckets. Keep an independent direct CLI byte contract as the
deterministic gate. Optimize a brief view only after repeated traces show that
it crosses a meaningful bucket, and preserve executable next actions while
removing duplicated prose or metadata. Rerun startup and real-operation timing;
smaller output is not an acceptable trade for slower startup or hidden reads.

## Topology experiments

The experimental unit is one generated case completed under both topologies.
The case fingerprint, model, candidate, logical role budgets, provider policy,
and scorer must match. Each case follows the frozen `profileOrder`; separately
validated cells may be combined only when their normalized experiment contract
is identical. A report rejects missing or duplicate cells.

Use the dry-by-default crossover controller for real-model studies. It turns
the frozen per-case profile order into one serial schedule, checks the wallet
against the remaining enforced cap and reserve before each cell, refuses an
uncertain replay, and resumes only a verified contiguous prefix. Manual launch
bookkeeping is not part of the experiment anymore.

Fresh roles can help through parallelism, independent judgment, information
separation, or context hygiene. A continuing context can help through retained
working state and lower coordination cost. The same continuity that saves a
handoff can also cause phase interference: options, assumptions, or unfinished
plans from one role may leak into the next. Reports should describe that
mechanism rather than saying only that “multi-agent won.”

Two historical trace diagnoses illustrate the required level of care. In one
distributed-resolution case, the fresh reviewer successfully read the prior
work and posted the requested reply, but stopped before the clearly advertised
resolve action; the continuing agent completed both. That is evidence of a
phase-boundary stopping failure, not missing durable state. Margin now exposes
an atomic reply-and-resolve action so a model need not remember a second state
transition. In a specialist handoff, a fresh reviewer received the complete
prompt, untruncated source, and prior decision, yet copied two generic command
placeholders literally; the continuing agent filled them correctly. That is a
working-state reconstruction and action-template failure, not prompt loss or a
CLI write failure. Structured manual pages now mark templates non-executable
and list every required replacement explicitly.

For each apparent topology effect, check the causal chain in order: whether the
role received its exact prompt; whether the needed document and prior durable
work were complete; whether every read/write call succeeded; whether the agent
selected, filled, and sequenced the right action; and only then whether fresh
versus continuing context explains the difference. Corroborating traces from
an infrastructure-invalid run may suggest a mechanism but never count as a
replicate.

The complete v19 breadth run adds four operating lessons:

1. Pace every provider request, not just process launches. A six-second shared
   request interval completed 191 calls without the prior 429, and the pacing
   contract was identical for both topologies.
2. Treat a fresh role's first response as a real resource boundary. One author
   spent its complete response budget reasoning and never acted. Classify that
   separately from missing handoff data, malformed commands, and ordinary turn
   exhaustion.
3. Make recovery instructions executable. When a stage is stale, the response
   should name the exact retained stage, root, and safe refresh command. A bare
   error code forces a new agent to reconstruct state it never held.
4. Keep safety separate from completion. Both multi-file attempts were partial,
   but neither partially applied a transaction. That is valuable product
   behavior even when the task score is low.

The public trace-shape artifact now records final model finish reasons and
benchmark stop conditions alongside command/error counts. It remains content
free, which makes cold-start output exhaustion distinguishable from a real
turn-limit stop without publishing conversations.

The post-v19 candidate checks add three more rules. First, repeat a claimed
mechanism under an exact matched candidate pair: the old and new handoff CLIs
both scored 100, so the earlier contrast was stochastic rather than causal.
Second, never rescue a seemingly good task result from a provider-invalid cell;
the first staged candidate run completed the visible work but a rate-limit flag
kept it out of evidence. Third, use the smallest surviving mistake to choose the
next product change. In the valid replacement stage pair, the new candidate was
safe and exact but spent one failed call discovering that `stage list` required
a root it was already standing inside. The next CLI therefore made only that
argument optional, with upward workspace discovery, rather than raising the
turn budget or broadening the prompt.

The replacement's 70.625-point score gain, four fewer invalid commands, and
safe atomic result are useful mechanism evidence. With one public pair they are
not a population estimate, a promotion, or permission to retune the case.

Four matched pairs are calibration. Ordinary directional language requires at
least 20 valid pairs in the reported cell, all safety gates passing, and the
paired uncertainty interval clearing the frozen quality or speed threshold.

## Wide-directory response budgets

A single-document size check does not represent directory collaboration. Test
wide orientation separately with enough distractor documents and open work to
force bounded discovery. Freeze the directory shape, relevant target, work-item
distribution, command, process order, and candidate binaries before measuring.

Measure direct response bytes and elapsed time first, without a model. Run both
candidates in counterbalanced order after warmups, and retain medians and p95s.
Then assert that the compact response reports truncation and supplies executable
follow-up actions; a small response that silently omits work is a failure. When
an early stop avoids enumerating the remaining tree, describe the observed
omission count as a lower bound instead of an exact total.

Use the checked-in instrument for this first gate:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli wide-directory-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin
```

The command normalizes generated fixture metadata, validates every document,
alternates arm order, refuses malformed command output, verifies that neither
arm changed the workspace, requires actionable file/work/guidance coordinates,
and emits a schema-backed model-free report. Empty-but-stable output cannot
pass.

The opt-in `wide_directory_triage` scenario is the second gate. It places one
typed question beyond a four-file brief overview in a 16-document workspace
with 64 distractor threads. The exact reference must recover through
`inbox --brief`, make one atomic reply-and-resolve write, verify the thread, and
validate the document. Keep this scenario outside the historical default set
until enough paired evidence justifies changing the benchmark population.

Only after those free checks pass should one cheap matched agent case ask the
agent to orient, select the relevant document, make a durable change, and
verify it. The paid comparison must examine response-size bucket, model input,
path to first write, commands, invalid calls, correctness, and omitted-work
recovery. A lower byte count alone is not evidence that agents collaborate
better. Preserve old scenario versions rather than changing their directory
width, because historical scores must remain reproducible.

## Concurrent-write mechanism gates

Keep three questions separate: whether every update is preserved, whether a
normal collision is scored fairly, and whether an agent has to see and recover
from that collision. A correct store can still impose avoidable coordination
work; a convenient retry can still be unsafe if it crosses a source edit.

Use deterministic tests to force collisions and prove source preservation,
identity preservation, bounded retries, and fail-closed explicit preconditions.
Then use the model-free paired probe to measure what reaches the agent:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli concurrency-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin \
  --repetitions 100
```

The probe starts both arms at the same barrier, alternates submission order,
and retains only aggregate call and conflict counts. Both arms must be exact,
safe, source-preserving, and free of invalid calls. The candidate must also use
four calls in every episode with no surfaced conflict. Baseline collision
frequency is descriptive, never a pass requirement: thread scheduling is a
source of measurement variation, not an oracle. Do not compare raw durations
from this contention probe as a launch-speed claim; use the separate
counterbalanced startup instrument for that question.

A model-free reduction in surfaced conflicts proves a mechanism improvement,
not better agent judgment. Buy a matched real-model case only when the research
question is whether the removed recovery burden changes completion, command
choice, tokens, or latency. Keep the benchmark's six-call safe-recovery path at
full efficiency so older binaries and real external conflicts are judged
fairly.

Natural model concurrency is not a reliable contention generator. In the first
public `suggestion_contention` pilot, both provider processes were concurrent,
but their inference latencies staggered all eight real writes. Both candidates
were exact and safe; the newer CLI used 23 rather than 25 visible interactions,
25 rather than 27 model calls, and 40.902 rather than 47.951 seconds, for scores
93.194 and 92.639. The complete pair cost $0.0107. Neither arm actually saw a
write conflict, so the small difference is calibration noise rather than retry
evidence.

That pilot also exposed two benchmark errors. Focused `suggest add --help`
requests were labeled as `suggest add`, inflating mutation counts, and an
unrelated explicit validation command obscured the mechanism under test. Help
is now classified separately, while durable list plus source read is the exact
verification route. The scenario now uses a disclosed benchmark-only lock
rendezvous for the first mutation. Five old-CLI reference cases then surfaced
2–4 stale-write results apiece and required 16–20 visible calls; twenty new-CLI
cases remained exact in the ideal 12 calls. The in-process and served fake-model
paths both still score 100 with two isolated traces.

The corrected public pair cost $0.0118. The old CLI surfaced one forced
`COLLABORATION_PRECONDITION_FAILED` result and recovered safely; the retrying
CLI surfaced no error. Both finished exact, safe, and source-preserving at
96.111, with 26 CLI calls and 28 model turns. The retrying CLI was 5.362 seconds
faster and $0.0004 cheaper, but the agent spent the saved recovery work on more
help, listing, inspection, and reading. This is positive mechanism evidence,
not evidence of lower total interaction cost. The next isolated variable is
therefore the built-in suggestion guidance: teach the shortest safe path for an
exact assignment, then rerun the same forced-contention pair. The
natural-scheduler pilot must never be reinterpreted under the corrected rules.

## Spend ladder

Every paid plan records both the conservative provider-contract maximum and a
smaller enforced live cap. Observed historical cost is planning evidence, not a
safety bound.

1. Free deterministic and fake-model gates.
2. One public cell on the cheapest useful model.
3. Its matched topology or candidate cell.
4. A four-family public breadth slice.
5. Fresh public repetitions of only stable mechanisms.
6. Rotating private confirmation with at least 20 matched cases.
7. A broader model matrix after task and runner behavior are stable.

Stop a campaign after any unsafe result, provider-bound violation, contract
drift, missing artifact, or unexplained scorer behavior. Preserve the redacted
incident receipt and require a new explicit run identity after correction.

## Promotion checklist

- Candidate and benchmark digests are frozen.
- Free gates pass in both supported Python runtimes and the pinned Swift
  toolchains.
- The exact plan, profile order, limits, price inputs, retry policy, and total
  live cap were fixed before inference.
- Every run and summary validates independently.
- The complete redacted bundle passes `marginbench audit-crossover` and its
  aggregate report reproduces from the published cells.
- Raw prompts, traces, paths, IDs, document content, and keys are absent from
  public artifacts.
- All candidate cases are safe and source-preserving.
- The intended metric improves on matched cases without a material regression
  in another primary dimension.
- Public evidence is confirmed on rotating private cases.
- The sample threshold and uncertainty rule are satisfied.
- App launch and CLI startup remain within the published performance envelope.

If any item is false, the result can guide another iteration but cannot promote
the product or support a leaderboard claim.

The checkpoint promotion command is intentionally narrow and idempotent. It
accepts only a supported summary/run schema pair, requires exact candidate,
model, episode, check, safety, source, and cost agreement, validates both files,
and creates only absent output files. An existing byte-identical artifact is a
safe replay; other existing data fails closed.
