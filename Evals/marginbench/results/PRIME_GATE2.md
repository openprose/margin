# Prime Gate 2: five-workflow calibration

Date: 2026-08-18 ET

Model: `qwen/qwen3.7-flash`

Harness: Prime Verifiers v1 null harness, one confined `margin` tool

Task set: fixed public-development repetition 0

Opening wallet: **$199.9861**

Latest wallet: **$199.9594**

Total observed debit: **$0.0267**

This phase calibrated MarginBench and the CLI interface. It was not a model
ranking. Each change responded to a concrete failure on a public development
case; none of these single samples is statistically sufficient for promotion.

## Strongest observed result by workflow

| Workflow | Candidate | Recorded score | Exact durable outcome | Invalid commands | Trace cost |
| --- | --- | ---: | :---: | ---: | ---: |
| Human relay | exact-command-context-v5 | 96.25 | Yes | 0 | $0.0009 |
| Agent handoff | fair-sampling-window-v6 | 100 | Yes | 0 | $0.0028 |
| Concurrent review | typed-work-guidance-v7 | 92.083333 | Yes | 1 | $0.0019 |
| Suggestion decision | mutation-next-actions-v8 | 89.821429 | Yes | 3 | $0.0037 |
| Staged multi-file | workflow-routed-tool-v10 | 92.5 | Yes | 1 | $0.0044 |

The human-relay file reached the exact required state. Its historical 96.25
score came from an earlier scorer requiring one particular read spelling; the
current oracle correctly treats the equivalent bounded read as valid and scores
that state at 100. The other sub-100 rows retained their scores because the
agents made avoidable invalid or excess calls even though their final documents
were correct.

## What the iterations taught us

1. Safe read aliases remove a common first-turn failure, but aliases alone do
   not teach the difference between starting a thread and replying to one.
2. Mutation receipts need to name the next durable action and the exact values
   to carry forward. Abstract verbs that resemble commands cause guesses.
3. A role needs enough response room to reach its first tool call; too-small
   output limits measure truncation rather than collaboration.
4. Typed workflow guidance materially improves concurrent work because agents
   stop treating every contribution as a generic comment.
5. Suggestion and stage recovery need compact workflow-specific discovery.
   Sending the entire capability catalog wastes context and invites irrelevant
   commands.
6. A stale immutable stage needs a first-class refresh operation. Reconstructing
   a hidden plan from a bounded stage preview is neither reliable nor fair.

These findings produced the current compact capability projections, typed
next-action receipts, stage refresh flow, and the progressive `margin man`
surface. All are general product behavior, not strings tailored to hidden
answers.

## Cost accounting

Twelve completed model attempts report **$0.0249** in aggregate. The Prime
wallet moved by **$0.0267** from the opening balance, leaving **$0.0018**
unreconciled. That difference includes the interval containing one provider
rate-limit attempt, but it is not attributed more precisely without provider
evidence.

An audit after the staged run found that the early wrapper's
`estimatedMaximumCostUSD` was not a valid billing ceiling. It used Verifiers'
deduplicated graph-token limit, while the provider bills repeated full prompts.
Paid calls stopped. The wrapper now requires a provider/model input ceiling per
call, multiplies it across every permitted turn and upstream retry attempt, and
adds a billing-rounding allowance. Historical files remain unchanged; see
[`COST_BOUND_AUDIT.md`](COST_BOUND_AUDIT.md).

## What is ready, and what is not

Ready:

- all five scenario families have a real-model end-to-end result;
- all strongest candidates preserved source integrity and workspace policy;
- the current no-model reference and Prime adapter matrices score 100;
- a real Prime-managed Linux sandbox ran Margin and validated a write;
- every result is redacted and raw traces remain ignored.

Not yet justified:

- a public model leaderboard;
- a claim that one candidate is statistically better;
- spending Gate 3 credits before repeated, paired, private cases are ready;
- publishing the hosted environment before the selected Prime team has an
  Environment Hub owner handle.

The complete attempt-by-attempt record is
[`EXPERIMENT_LEDGER.json`](EXPERIMENT_LEDGER.json).
