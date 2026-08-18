# Prime paid-run cost-bound audit

Date: 2026-08-18 ET

Status: corrected and backed by a tested live request/spend gate

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
used as billing maxima. The dollar cap remains an explicit pre-run admission
gate. Paid execution now adds a second, live boundary described below.

## Regression evidence

With a deliberately small 65,536-token asserted per-call ceiling, the corrected
two-role bound is $0.178422. A dry plan with the old $0.01 cap is refused before
creating an output directory or calling a model; a $0.18 cap emits a no-model
plan whose full assumptions are machine-readable. Unit coverage also asserts
that this bound exceeds the observed $0.0044 staged debit.

No paid run was started during or after this correction.

## Subsequent contract evidence

Alibaba's current official model table now documents `qwen3.7-flash` at a
1M-token context:
https://help.aliyun.com/zh/model-studio/text-generation-model/ . Prime's
authenticated Models API reports the served model at $0.03/M input and $0.13/M
output. Three later serial directory-handoff calibration cells therefore used
1,000,000 as the asserted per-call input ceiling. Their conservative admission
bound was $1.82136 each; observed debits were $0.0026, $0.0032, and $0.0039.

This evidence also makes a broad default study's pessimistic bound much larger:
$48.331008 per candidate and $96.662016 for the pair. No such study was started.

## Live enforcement added

Paid execution now places a loopback-only proxy between Verifiers and Prime
Inference. The parent process keeps the real Prime key; the child receives only
a random, short-lived local capability. Before forwarding a request, the proxy:

1. accepts only the priced model and exact non-streaming chat-completion route;
2. requires finite output tokens and rejects an oversized encoded request;
3. reserves a conservative token-and-overhead cost under a locked cumulative
   cap, never releasing a reservation after a provider error; and
4. forwards only minimal headers, bounds the provider response, and retains no
   prompt, response, document, key, or raw trace content.

Its redacted report publishes policy, forwarded/rejected counts, conservative
reservations, and provider-reported token totals. Schema validation recomputes
the reported token cost and proves the reservations stay within the live cap.
The complete six-scenario, 59-call fake-model matrix passed through this proxy
both in process and across Prime's out-of-process environment-server boundary:
all six rewards were 1.0, all 59 fake-provider requests matched proxy forwards,
zero requests were rejected, and no paid model was invoked.

The live cap defaults to the already reviewed static run cap. It does not
rewrite historical artifacts and it does not substitute observed low cost for
the conservative provider-contract admission bound.

A final $0.02-capped real-provider smoke verified the complete path. Its
unproxied contract maximum was $0.181824. Six Qwen Flash requests were forwarded
and none rejected; conservative reservations reached $0.008847, the wallet and
trace each reported $0.001, and both redacted artifacts validate with the same
live policy. No retry ran.

Paired plans now preserve both numbers rather than choosing one: every job
records its unproxied provider-contract maximum and its enforced proxy cap, and
the study records both aggregates. Validation recomputes both and rejects a
changed cap. At $0.05 per job, the default 24-pair/48-job plan retains its
$96.662016 unproxied maximum while enforcing $2.40 across the study; a first
matched-pair checkpoint can reserve at most $0.10.
