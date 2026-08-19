# MarginBench iteration loop

Status: active operating procedure, 2026-08-19.

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
