# Prime paid-run cost-bound audit

Date: 2026-08-18 ET

Status: corrected before any broader paid matrix

## What failed

The original paid wrapper estimated maximum cost from Verifiers'
`max_input_tokens` and `max_output_tokens` fields. That was not a valid provider
billing bound. Verifiers 0.3.0 documents those as per-rollout message-graph
limits checked between turns. The input graph stores shared conversation
prefixes once; the inference provider bills the entire prompt on every model
call.

The staged multi-file run exposed this mistake without breaching the user's
spend limit:

- old estimate: $0.003960;
- trace-reported and wallet debit: $0.004400;
- billable prompt tokens across both roles: 107,457;
- completion tokens across both roles: 3,559;
- completed model calls: 19;
- result: exact final state, 92.5 score, safety passed.

The historical result remains unchanged. Its `estimatedMaximumCostUSD` field is
a nominal framework-budget estimate and must not be interpreted as a maximum.

## Correction

Every new paid plan must provide `--input-token-ceiling-per-call`, sourced from
the provider/model contract. The admission calculation now assumes, for every
role process:

1. every allowed turn reaches that full input ceiling;
2. every response reaches the hard per-call sampling ceiling;
3. every turn consumes the configured SDK upstream-attempt allowance; and
4. every upstream attempt incurs an additional billing-rounding allowance.

The Verifiers graph-token limits remain useful live controls, but they are not
used as billing maxima. The dollar cap is explicitly a pre-run admission gate,
not a live wallet cutoff. Process, turn, response-token, and wall-time limits
are the live controls.

## Regression evidence

With a deliberately small 65,536-token asserted per-call ceiling, the corrected
two-role bound is $0.178422. A dry plan with the old $0.01 cap is refused before
creating an output directory or calling a model; a $0.18 cap emits a no-model
plan whose full assumptions are machine-readable. Unit coverage also asserts
that this bound exceeds the observed $0.0044 staged debit.

No paid run was started during or after this correction.
