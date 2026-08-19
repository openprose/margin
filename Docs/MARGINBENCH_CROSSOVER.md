# MarginBench collaboration-crossover design

Status: implemented and model-free baseline measured, 2026-08-18. Exact
measurements are in
[`MARGINBENCH_CROSSOVER_RESULTS.md`](MARGINBENCH_CROSSOVER_RESULTS.md).

## The question

MarginBench must not assume that more agents are better. It measures where a
team becomes more useful than one continuing agent, and where the handoff cost
still dominates.

The primary comparison is paired: the same generated case is run once with
separate role contexts collaborating through Margin and once with one context
performing the same logical roles in the same order. Both sides receive the
same role briefs, Margin build, model, sampling, total role-turn allowance, and
maximum provider cost. Only the topology changes.

There is no universal collaboration score. The report keeps quality, safety,
elapsed time, tokens, cost, command errors, and recovery separate, then shows
how their paired differences change with the demands of the task.

## Collaboration demand axes

Every challenge has a public, static profile on seven axes from 0 through 4.
The values describe the task, not a model's result.

| Axis | 0 | 4 |
| --- | --- | --- |
| Parallelism | Work is inherently serial | Independent useful work can occur at the same time |
| Information distribution | Everyone starts with the same facts | Required facts are split across roles or locations |
| Specialization | Roles use the same judgment | Roles require meaningfully different expertise or criteria |
| Review independence | No fresh judgment is needed | Correlated author error is a central risk |
| Workspace volatility | State is static | Concurrent or external changes must be reconciled |
| Continuity | One uninterrupted session suffices | Durable state must survive a boundary or interruption |
| Coupling | Work products are independent | Changes interact and coordination errors are likely |

High coupling is not automatically pro-collaboration. It raises both the value
of explicit coordination and its cost. Reports therefore show it separately.

## Challenge breadth

The first crossover suite contains the existing protocol cases plus three new
demand-focused cases.

| Challenge | Primary reason to collaborate | Expected use in the study |
| --- | --- | --- |
| Human-to-agent relay | Human continuity | Basic human boundary |
| Agent-to-agent handoff | Durable continuity only | Negative control: continuing context should usually win |
| Concurrent review | Parallel work on shared state | Parallelism under write conflict |
| Suggestion decision | Independent decision plus source drift | Review and volatility |
| Staged multi-file update | Atomic work across files | Coupled, volatile workspace |
| Directory handoff | Facts spread across a directory | Information discovery and continuity |
| Parallel shards | Independent files reviewed at once | Clean parallelism with little coordination cost |
| Specialist audit | Performance author checked by a security reviewer | Specialization and independent correction |
| Distributed synthesis | Each role owns a fact needed for the answer | Necessary durable information transfer |

The handoff case is deliberately retained even if collaboration loses. A
benchmark without negative controls would reward orchestration for its own
sake.

## Benchmark architecture

The implementation is split into six layers so an improvement in one layer
cannot silently redefine another:

1. The keyed case generator creates source files, role-private facts, scripted
   workspace changes, exact expected annotations, and a one-way case
   fingerprint.
2. The topology controller runs that one case either as fresh role contexts or
   as one continuing context. It binds authored identity outside model control
   and keeps the logical-role budget fixed.
3. The confined Margin gateway is the only action surface. It enforces path,
   identity, input, output, and timeout bounds while recording content-free
   command telemetry.
4. The deterministic scorer reads the final workspace and checks exact facts,
   source preservation, attribution, document validity, recovery, and command
   policy. No model judges another model.
5. The crossover analyzer accepts only complete, build-matched, fingerprint-
   matched pairs. It retains the raw dimensions and creates family and
   demand-level summaries.
6. The publisher validates bounded JSON artifacts and excludes prompts, hidden
   facts, source text, raw tool responses, traces, keys, and local paths.

The report embeds its public crossover plan, so one file proves which cases,
catalog, candidate, profiles, order, thresholds, and sample size were declared.
Measurements that do not exactly cover that plan are rejected.

This separation supports three kinds of iteration without confusing them:
changing Margin's interface, changing team topology, or changing the model.
Only one should vary inside an ordinary experiment.

## Experimental unit and estimands

The experimental unit is a matched generated case, not a conversation and not
a role trace. A two-role team therefore still yields one observation. The
primary paired quantities are:

- score and dimension differences, role-separated minus continuing;
- check failures on each side, without converting safety into a soft penalty;
- elapsed-time ratio, continuing divided by role-separated, so values above one
  indicate a team speedup;
- differences in command count, invalid commands, calls, tokens, and cost.

Elapsed ratios are combined with a geometric mean so one near-zero timing does
not dominate a cell. Score means and both score and speed uncertainty intervals
use a deterministic paired bootstrap. Reports show the number of pairs and the
four-way count of role-separated, continuing, inconclusive, and unsafe cases.

The first analysis is a crossover map, not a causal model of every axis. Axis
levels are intentionally interpretable but correlated: for example, source
volatility and coupling often occur together. Once the public suite has enough
models and private repetitions, a second preregistered analysis can estimate
interactions with a hierarchical paired model. That later analysis must not be
retrofitted onto the first results.

Execution block is a separate nuisance variable. A within-block paired
bootstrap captures variation between cases but cannot capture a slow machine,
provider interval, or thermal state shared by a whole block. Public latency
claims should therefore repeat a complete interleaved schedule in at least
three blocks and disclose all block-level ratios. A later multi-model analysis
should model cases inside execution blocks rather than treating every case as
independent across time or machines.

## Fair controls

The initial crossover compares:

1. `role-separated-margin-only-v1`: one model context per logical role; only
   Margin state crosses the boundary.
2. `single-agent-margin-v1`: one continuing context receives the same role
   briefs phase by phase; Margin binds the correct authored identity in each
   phase.

The budget unit is a logical role, not a process. If a case has two roles, the
continuing process receives the sum of both role budgets. Parallel agents may
improve wall time but do not receive extra total turns or a larger cost cap.
Profile order is counterbalanced within each scenario across repetitions.
Cases from different challenge families are then placed in one deterministic
digest-keyed execution order rather than run as family-sized clusters, reducing
confounding from machine or provider drift.

Later representation controls—plain Markdown, Margin plus a shell, and no
exchange—remain separate experiments. They require representation-neutral
oracles and their own safety boundaries before execution.

## What is measured

For every matched case the public report records:

- exact outcome and safety on both sides;
- score difference without treating it as the only result;
- elapsed-time ratio and difference;
- total model calls, prompt, completion, cached, and reasoning tokens;
- observed cost;
- Margin command count and invalid-command count;
- whether required conflict recovery or continuity succeeded;
- the static collaboration-demand profile.

The report groups those paired observations by challenge family and by every
axis level. It does not average unrelated families into a leaderboard number.
A cell can be described as role-separated-favored only when collaboration is
safe, is not materially worse in quality, and improves a predeclared primary
measure such as elapsed time or defect detection. Continuing-favored and
inconclusive cells use symmetric rules. Confidence intervals and sample counts
must accompany every conclusion.

## Validity rules

- Cases, axes, primary measures, retry policy, and thresholds are frozen before
  private inference.
- A public-development result can debug the benchmark but cannot promote a
  product or model.
- Incomplete or terminal infrastructure failures are never scores.
- The policy for a recovered, pre-budgeted provider retry must be decided
  prospectively and tested before another paid topology run.
- Time includes orchestration, tool use, and recovery. Cost includes every
  provider attempt allowed by the frozen plan.
- Raw prompts, role-private facts, traces, and holdout keys are not published.
- At least 20 valid matched cases are needed for an ordinary directional claim;
  family-level claims require sufficient matches inside that family.

## How a cell is interpreted

Safety is a gate. Any document damage, invalid protocol state, path escape, or
lost atomicity marks the affected cell unsafe regardless of speed or score.
Among safe pairs, a score difference beyond two points leads. If quality is
within that frozen tolerance, a wall-time ratio of at least 1.20 favors the
role-separated topology and a ratio at most 1/1.20 favors the continuing
topology. Everything between those thresholds is inconclusive. A descriptive
leader becomes a directional conclusion only after 20 valid matched cases in
that reported cell and its paired uncertainty interval clears the relevant
boundary. A speed claim also requires the complete score interval to remain
inside the quality-tie tolerance.

This rule is intentionally conservative. It does not claim that a fast team is
better when it produces worse work, and it does not claim that a tiny timing
difference justifies the extra contexts.

## Public benchmark protocol

A public `collab-bench` style release can use three partitions:

- public development cases and the no-model reference policy for integration;
- public calibration cases for estimating runtime and setting budgets;
- rotating private cases for model or interface comparisons.

An official submission should bind the benchmark commit, Margin binary and
manual digests, challenge-catalog digest, model identifiers, sampling and
provider limits, generation-key ID, topology order, redacted run artifacts,
and crossover report. The benchmark operator runs private cases; submitters do
not receive their key or oracle. Raw traces remain private because they may
contain generated facts even when the public report does not.

Leaderboard views should expose a Pareto surface—quality, safety, latency,
tokens, cost, and command friction—plus family and demand slices. They should
not rank systems by one weighted collaboration number. A system can credibly
claim, for example, strong independent review and distributed synthesis while
remaining a poor choice for a serial handoff.

## Spend ladder for real models

The no-model gates run first. A paid campaign then expands only when the prior
gate produces valid, topology-complete evidence:

1. one public matched pair on the serial negative control;
2. one pair each for clean parallelism, specialist review, and distributed
   synthesis;
3. three public repetitions across those four families;
4. at least 20 private matched cases for any directional claim;
5. a broader model matrix only after the task and orchestration effects are
   stable.

Every gate freezes a maximum model-call, token, time, and dollar bound before
inference. Provider or harness failures are diagnosed separately and do not
become task scores. A recovered retry policy must be fixed before the run, not
chosen after seeing which topology failed.

## Implementation and measurement gates

1. Publish a schema-validated challenge catalog containing all demand profiles.
2. Make every challenge reproducible from the public or private generation key.
3. Require the deterministic reference policy to score 100 on every challenge.
4. Exercise both topologies in process and through the real environment-server
   boundary with no paid model.
5. Publish a schema-validated crossover plan binding cases, profiles, budgets,
   order, and challenge-catalog digest.
6. Publish a schema-validated crossover report that rejects missing, duplicate,
   mismatched, unsafe, or infrastructure-invalid pairs and binds one identical
   model, runtime, limit, retry, cost, build, and case-partition contract.
7. Measure local protocol cost and prove the analysis recovers known crossover
   behavior before requesting model spend.
8. Start paid work with a small public slice spanning a negative control, clean
   parallelism, independent review, and distributed information. Inspect it
   before private holdouts or a broader model matrix.

Progress:

- [x] Challenge catalog and seven-axis demand profiles.
- [x] Nine keyed, deterministic, execution-scored challenges.
- [x] Role-separated and continuing-agent control paths.
- [x] Counterbalanced matched crossover plan.
- [x] Deterministic cross-family interleaving to reduce execution-order drift.
- [x] Schema- and semantics-validated crossover report with embedded plan.
- [x] Exact topology-neutral experiment-contract matching across both sides.
- [x] In-process and environment-server fake-model isolation gates.
- [x] 180-pair no-model mechanics baseline.
- [x] Three interleaved execution blocks exposing between-block timing drift.
- [x] Small, capped public real-model crossover across four challenge families.
- [x] Dry-by-default, resumable, serial paid crossover controller with per-cell
      and whole-study caps and no automatic retry.
- [ ] Rotating private confirmation for any directional model claim.
- [ ] Broader multi-model public benchmark after calibration.
