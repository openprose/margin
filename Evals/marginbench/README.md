# MarginBench

MarginBench measures whether agents can collaborate with a human and with one
another through durable Markdown state. It runs real Margin commands in an
isolated workspace and scores the resulting files. It does not ask another
model to judge the transcript.

The benchmark is provider-independent. `marginbench/` contains the generator,
gateway, runner, scorer, and candidate comparison code. `marginbench.prime` is
the first hosted adapter, built for Prime Intellect Verifiers v1.

## What v1 measures

The nine current scenario families cover:

- replying to and resolving a human's existing review thread;
- leaving a durable handoff that a second agent can find without a transcript;
- two agents writing concurrently without losing or duplicating work;
- proposing two exact source changes and accepting one while safely rejecting
  the other after its source cursor becomes stale;
- staging one all-or-none change across two files, observing stale metadata,
  refreshing the immutable stage, and submitting it atomically;
- triaging a human thread in one directory document, leaving a typed handoff in
  another, and having a second agent discover and complete it from root context
  without receiving the first agent's transcript;
- reviewing independent file shards concurrently, with no shared-write excuse
  for a missing speedup;
- having a performance author checked by a fresh security reviewer with a
  role-private rule; and
- combining facts initially split between two roles through durable state.

Each case is generated deterministically from a secret key and repetition
number. Public development cases use a documented key. Private evaluation cases
use a rotating key supplied only to the task generator.

## Trust boundary

An agent receives its role brief and one tool named `margin`. The gateway:

- binds the role's actor identity;
- confines paths to the episode workspace;
- blocks GUI launch routes, identity overrides, oversized input and output, and
  non-Margin commands;
- invokes the real Margin executable with a shared lock/state directory;
- records only role, command path, byte counts, timing, exit code, and stable
  error code. Arguments, document text, comment bodies, prompts, and credentials
  are not written to the benchmark event log.

The hidden fixture and executable oracle remain in the environment process, not
in the task data or agent runtime. Raw provider traces can still contain task
prompts and tool responses; `runs/` is ignored and must be treated as private.
When Prime serves the environment out of process, the wire carries only the
scenario, repetition, control profile, and one-way case fingerprint. The trusted
server regenerates the hidden episode from its key and rejects a fingerprint
mismatch before creating any agent process. A private key remains available only
long enough for that trusted worker to inherit and verify the episode; the worker
then removes it from its environment before resolving Margin, creating the
workspace or gateway, or starting an agent. Each agent receives a plain role task
with no episode, fixture, oracle, or key attribute.

## Local, no-model gates

From the Margin repository root:

```sh
make marginbench-test
make marginbench-audit
make marginbench-preflight
```

`marginbench-test` runs the Python contracts under both the system interpreter
and Prime's Verifiers environment, then requires the deterministic reference
policy to score 100 on every scenario. `marginbench-preflight` runs every role
in all nine Verifiers v1 scenarios through a local fake OpenAI-compatible model,
first in process and then across Prime's real environment-server boundary.
Neither command invokes a paid model. CI also repeats the served path with a
fresh private key, publishes only its one-way key ID, then overwrites and deletes
the key in the same job. A public preflight ignores any ambient holdout-key
variable unless `--holdout-key-file` was explicitly supplied.

`marginbench-audit` verifies every tracked redacted crossover bundle,
recomputes each aggregate report, and verifies every tracked candidate-study
submission. It is also part of `marginbench-test` and the portable CI gate.

The same gates are encoded in `.github/workflows/marginbench.yml` for a clean
Ubuntu runner. The workflow has read-only repository permissions, uses no
secrets or paid service, rebuilds the published x86-64 binary against its
tracked digest, runs the Prime fake-model rehearsal, exercises the wheel inside
the pinned Python/Linux image, and retains only the package plus a redacted
validation receipt.

Individual commands are also available:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli generate \
  --scenario human_agent_relay --repetition 0

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli reference \
  --margin-bin build/margin --scenario concurrent_review

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli self-test \
  --margin-bin build/margin

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli wide-directory-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli concurrency-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin --repetitions 100

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli \
  suggestion-convergence-probe \
  --baseline-bin PATH_TO_PRE_WAIT_BINARY --candidate-bin build/margin

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli contention-matrix \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin \
  --repetitions 8

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli neutral-feasibility

PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/python -m marginbench.cli \
  neutral-served-preflight

PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/python -m marginbench.cli \
  neutral-isolation-preflight

PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/python -m marginbench.cli \
  neutral-production-preflight

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli efficiency-report \
  build/benchmarks/neutral-served-preflight.json \
  Evals/marginbench/results/crossover/v17/cells/*.run.json \
  > build/benchmarks/efficiency-report.json

# If paid model work completed but a later validator rejected publication:
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli promote-checkpoint \
  Evals/marginbench/runs/PRIVATE_RUN_DIRECTORY \
  --summary-file PUBLIC_SUMMARY.json --run-file PUBLIC_RUN.json
```

`neutral-feasibility` invokes no model. It proves that all nine hidden outcome
shapes can be represented and completed through the confined ordinary-Markdown
gateway, then validates exact facts, source integrity, historical all-or-none
visibility, trusted attribution, read-before-action continuity, and required
stale-write recovery. It lists agent efficiency as not evaluated because no
model runs in this check.

`wide-directory-probe` invokes no model. It creates byte-identical copies of a
deterministic 16-document, 64-item workspace; alternates baseline and candidate
process order after warmups; checks stable JSON shape and source preservation;
requires nonempty files, work, guidance, action paths, roots, and revisions;
and reports response bytes plus median and p95 elapsed time. Generated document
IDs and timestamps are normalized, then every embedded comment block is
validated before measurement. The result uses
`urn:marginbench:wide-directory-probe:v1` and can be checked with
`marginbench validate`. It is a mechanism gate, not evidence of improved model
performance.

`concurrency-probe` also invokes no model. It starts the published baseline and
candidate together for each repeated two-writer review episode, counterbalances
submission order, binds the generated case set by digest, and reports
agent-visible conflicts plus recovery-command overhead. Success requires both
arms to remain exact, safe, source-preserving, and free of invalid calls. The
candidate must additionally use the normal four visible calls in every episode
and surface no conflict. The baseline's collision count is descriptive: a run
remains valid when scheduler luck produces no baseline collision. The
schema-bound report is
`urn:marginbench:concurrency-probe:v1` and can be checked with
`marginbench validate`. Both retained model-free probe families are also part
of `make marginbench-audit`, so a stale or hand-edited report fails the normal
publication gate. The current 1,000-pair development result is
`results/concurrency/v41-model-free.json`.

`suggestion-convergence-probe` invokes no model. It gives both arms the same
known first suggestion, adds a second suggestion after controlled 200, 500,
and 1,000 ms delays, and starts the arms together with counterbalanced process
order. The baseline checks `suggest list` repeatedly; the candidate makes one
named `suggest wait` call. Verification reads are excluded from the measured
convergence count but still require both exact suggestions, a valid comment
graph, and byte-identical logical Markdown. The report contains only aggregate
counts, timings, binary digests, and a generated case-set digest. It uses
`urn:marginbench:suggestion-convergence-probe:v1`, is checked by
`make marginbench-audit`, and is mechanism evidence rather than a model-quality
claim. The current retained result is
`results/convergence/v61-model-free.json`.

`contention-matrix` invokes no model and uses real, simultaneous CLI processes.
By default it tests groups of 2, 4, 8, and 16 actors across five meanings of
concurrent work: independent typed additions, independent suggestion additions,
independent suggestion rejections, competing source-changing acceptances, and
cursor-bound handoffs. The first three should converge without making agents
perform a read/retry storm. Suggestion acceptance must leave exactly one source
winner, and handoff conflicts must stay visible because silently changing a
handoff's starting state would falsify its provenance. The report separates
source and graph safety from completion, independently recomputes every total,
and retains only aggregate counts, end-to-end timings, binary digests, and
static error codes. Internal retry counts are not exposed by the product, so
the report measures the calls an agent must make and the total elapsed cost of
the complete operation. Baseline incompletion is descriptive; baseline safety
and all candidate safety/completion checks remain mandatory. The schema-bound report is
`urn:marginbench:contention-matrix:v1`, retained reports are checked by
`make marginbench-audit`, and the current model-free result adds the supported
32-actor ceiling with repeated `--group-size` flags at
`results/contention/v45-model-free.json`.

`wide_directory_triage` is an opt-in experimental scenario rather than a tenth
default family. It requires brief orientation, recovery through a filtered
brief inbox, one exact reply-and-resolve write, and verification in a
16-document/64-distractor workspace. Run it explicitly with
`marginbench reference --scenario wide_directory_triage`; stable nine-family
studies remain unchanged.

`suggestion_contention` is also opt-in. Two agents independently author four
exact suggestions each against one shared document. A benchmark-only
rendezvous briefly holds Margin's ordinary document lock when their first real
suggestion mutations (`suggest add` or `suggest batch`) arrive, so both CLI
processes evaluate the same initial
state before either transaction may commit. This removes provider-timing and
scheduler luck from the stale-metadata test without fabricating a CLI response
or bypassing Margin's normal validation and write path. The old candidate must
surface and recover from the forced collision; a candidate with safe internal
metadata retries should keep the collision invisible. Both must preserve the
literal Markdown, all eight identities, bodies, anchors, replacements, and
actor attribution. Focused `--help` calls are recorded as help, never as the
mutation they document. The deterministic cross-version reference continues to
use individual additions; the fake-model product rehearsal uses one atomic
batch when the candidate advertises it and falls back to individual additions
when it does not.

The plain control has one Prime-served tool named `workspace`.
It discloses `guide`, `list`, `read`, and compare-and-swap `write` progressively,
uses a private locked cross-process event record, and has passed one complete
two-role handoff without a Margin binary.

`neutral-served-preflight` is also model-free. It sends all nine public role
briefs through separate Prime-served tool sessions, validates their final
neutral state, and emits only content-free measurements. An independent prompt
audit covers 85 role briefs, and `neutral-isolation-preflight` proves 17 fresh
role processes never inherit another role's transcript.

`neutral-production-preflight` invokes Prime's real evaluation command against
a local scripted endpoint. Across all nine workflows it validates 17 role
traces, 105 model-shaped requests, 88 same-role transcript continuations, both
official result formats, and zero cross-role leaks without invoking a paid
model. These gates make `role-separated-plain-markdown-v1` runnable. Its real
results remain non-scalar: they can be compared with Margin only as explicit
outcome and resource vectors, never as one synthetic winner.

`efficiency-report` consumes schema-valid served-neutral receipts, real plain
control runs, and redacted Margin run artifacts. It reports elapsed time, tool round trips,
failures, bytes, tool time, model calls, tokens, and reported cost as separate
measurements. Every source is bound by its byte count and SHA-256 digest;
missing measurements remain `null`. The schema permanently forbids a scalar
ranking or winner, and labels scripted-versus-model observations as mixed
execution rather than treating them as a fair speed contest. For real-model
pairs it also hashes 37 content-free contract fields and reports `matched`,
`mismatch`, or `insufficient-metadata`; a shared episode ID is never treated as
proof that model, sampling, limits, topology, task build, and budget policy were
the same. The normal
`marginbench-neutral-preflight` gate regenerates and validates this report.

## Find where collaboration actually helps

The crossover track compares the same candidate on the same hidden case under
two topologies: separate role contexts communicating only through Margin, and
one continuing context performing the same logical roles. The logical-role
budget is identical; only context separation and the ability to work in
parallel change. Challenge demand is declared on seven public axes, including
parallelism, distributed information, specialization, independent review,
workspace volatility, continuity, and coupling:

```sh
marginbench challenges > challenge-catalog.json
marginbench crossover-plan --candidate released --repetitions 3 \
  > crossover-plan.json
marginbench crossover-reference --margin-bin build/margin --repetitions 20 \
  > crossover-reference.json
marginbench validate crossover-reference.json
```

The reference run invokes no model. It proves that cases, both execution paths,
scoring, pairing, statistics, and publication work, while its timing describes
only local harness mechanics. A real model study runs the two profiles with the
same model and frozen limits, then combines their completed redacted runs:

```sh
marginbench crossover-report --plan crossover-plan.json \
  role-separated-run.json continuing-run.json \
  > crossover-report.json
```

For a paid study, `crossover_pilot.py` replaces manual cell launches. It is
dry-run by default, flattens every case in its frozen `profileOrder`, records
the unproxied contract maximum beside the enforceable per-cell and whole-study
caps, and runs serially with no automatic retry:

```sh
Evals/marginbench/crossover_pilot.py \
  --crossover-plan crossover-plan.json \
  --candidate-manifest candidate.json --candidate-bin build/margin \
  --model qwen/qwen3.7-flash \
  --input-token-ceiling-per-call PROVIDER_DOCUMENTED_LIMIT \
  --input-token-ceiling-source https://provider.example/model-contract \
  --input-price-per-million 0.03 --output-price-per-million 0.13 \
  --pricing-source https://provider.example/model-pricing \
  --live-proxy-cap-per-cell-usd 0.03 --max-study-cost-usd 1.20
```

Paid execution requires the separate literal confirmation shown by `--help`.
The controller freezes the candidate, binary, crossover plan, and private key
when applicable; verifies and skips an already completed contiguous prefix;
stops on partial, unsafe, source-damaging, budget-invalid, or contract-drifting
evidence; and emits the validated crossover report only after every matched
cell completes. `--max-new-jobs 1` provides a cheap, resumable first-cell gate.

The report deliberately has no universal collaboration score. It retains every
outcome check and scoring dimension, safety and source integrity, elapsed-time
ratio and confidence interval, commands and errors, model calls, tokens, and
cost. It shows results by challenge family and by each demand level. Fewer than
20 valid matched cases may be described but cannot support a directional
claim. Infrastructure failures are rejected instead of becoming low scores.
The complete design is in `Docs/MARGINBENCH_CROSSOVER.md`.

An installed Linux package may simply run `marginbench self-test`; it discovers
its bundled executable, verifies the binary against the embedded manifest, and
never downloads code at runtime.

## Turn results into the next interface experiment

`marginbench diagnose` accepts one or more validated result, redacted run, or
Prime summary artifacts and ranks the concrete failure classes worth addressing:

```sh
marginbench diagnose baseline-run.json candidate-run.json \
  --focus-candidate candidate-v2 > diagnosis.json
marginbench validate diagnosis.json
```

The report distinguishes actual document damage from a disallowed operation
that the workspace boundary successfully blocked, then separates incomplete
durable work, missed recovery, invalid command forms, attribution, interaction
count, and early agent stops. It breaks
the evidence down by candidate and scenario, recommends changing one interface
surface at a time, and requires at least 20 matched private episodes before an
ordinary promotion. When several candidates are present, an explicit focus is
required so an old baseline failure cannot block—or excuse—the candidate under
test. Any safety or source-integrity failure in that focus candidate instead
sends it back to local testing with no paid expansion.

Diagnostics read each input once with the normal 16 MiB bound. They retain only
artifact digests, scores, checks, command-path/error counts, and public case IDs;
they do not retain artifact paths, document text, prompts, raw traces, or keys.
The paired Prime controller creates `diagnostic.json` automatically when a study
finishes, verifies that it covers exactly the published redacted runs, and binds
its digest and top-ranked opportunity into the completion receipt.

## Validate publication artifacts

Every current publication format has a bundled JSON Schema plus bounded
cross-field checks. Validation is local, reads at most 16 MiB, rejects duplicate
JSON keys and non-finite numbers, and never calls a model or network service:

```sh
marginbench validate run.json
cat study-plan.json | marginbench validate -
marginbench audit-crossover results/crossover/v17
```

The command prints a `urn:marginbench:validation:v1` receipt containing the
artifact's declared schema, byte count, and SHA-256. Exit status is 0 only when
both the schema and semantic totals agree; malformed, unsupported, or tampered
artifacts return status 65. Supported evidence includes episode results,
reference runs, candidate manifests, study plans, paired comparisons, paid-run
summaries, redacted run manifests and ledgers, runtime probes, control catalogs,
Prime paired-study plans and completed-job receipts, and binary manifests. The
validator itself is packaged with MarginBench, so a
reviewer does not need this source checkout.

`audit-crossover` goes beyond validating files one at a time. It verifies the
entire redacted topology experiment as a coherent unit: candidate and plan
bindings, one matching run and summary per topology, complete paired coverage,
and an aggregate report reproduced from the published cells. Unexpected raw
traces, symlinks, or unrelated files make the audit fail without their contents
being read or echoed.

### Build and verify a leaderboard bundle

Validating each JSON file separately does not prove that the files belong to
the same experiment. A publication bundle therefore has one deterministic
submission manifest that binds the two candidates, private or public study
plan, its deterministic execution plan, every redacted run manifest, and
paired comparison by path and digest.
Create it only after all referenced files are in one directory tree:

```sh
marginbench submission create publication \
  --baseline-manifest candidate-baseline.json \
  --candidate-manifest candidate-new.json \
  --study-plan study-plan.json \
  --execution-plan execution-plan.json \
  --comparison comparison.json \
  --run runs/baseline-1.json --run runs/candidate-1.json \
  > publication/submission.json

marginbench submission verify publication/submission.json
```

Creation fails unless the run set covers every study-plan episode exactly once
for each candidate and agrees on the benchmark, track, control, candidate
digests, benchmark-implementation digest, case fingerprints, and track-specific
fixed execution settings. It also prevents a comparison from lowering the
promotion threshold frozen in the study plan. Verification rereads the bundle,
checks every recorded digest and schema, and recomputes the paired comparison from the
redacted episode measurements. It never needs prompts, raw traces, fixtures, or
the holdout key. The verifier reads each file once, caps files at 16 MiB and the
whole referenced bundle at 64 MiB, rejects path escape and symlink references,
and emits a machine-readable verification receipt.

The manifest is a portable integrity record, not a submitter signature and not
proof of execution chronology. Official leaderboard intake should separately
authenticate the submitter and run the private cases under benchmark-controlled
orchestration. Run manifests created before the publication fields
`sourcePreserved`, `durationMs`, and per-episode `marginSha256` were introduced
remain historical evidence but cannot enter a recomputable v1 submission.

## Linux artifact

Prime-hosted and other container evaluations use the same Swift core and CLI as
the Mac application. Build reproducible x86-64 and arm64 Linux executables with:

```sh
make marginbench-linux-binary
```

The build uses the pinned Swift 5.10 Jammy image in
`docker/Dockerfile.margin`. Generated executables live in
`marginbench/bin/`; they are intentionally not committed because together they
are roughly 90 MB. Release packaging includes them, while a source checkout can
rebuild them or set `MARGINBENCH_MARGIN_BIN` to an existing Linux executable.
Published binary digests belong in `BINARY_MANIFEST.json`.

## Prime Verifiers v1

The package exports one task set and one multi-agent environment, both named
`marginbench`. Prime authentication follows the official CLI login and selected
team; no key is copied into this repository.

A configuration-only check is safe and free:

```sh
PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/eval marginbench \
  --model qwen/qwen3.7-flash \
  --num-tasks 1 --num-rollouts 1 --max-concurrent 1 \
  --env.taskset.scenario-ids human_agent_relay \
  --env.taskset.margin-binary "$PWD/build/margin" \
  --push false --rich false --dry-run true
```

Remove `--dry-run true` only under an explicit spend gate. Always set finite
turn, input, output, total-token, and rollout-time limits. Do not publish or
commit the resulting raw trace directory.

The repository's safer paid wrapper is dry-run by default, requires a literal
confirmation, discloses the unproxied contract maximum separately from the
enforced run cap, serializes starts behind
a cooldown, records wallet deltas, aggregates multiple role traces into one
episode result, and can emit a schema-validated public run manifest. Paid
execution also routes every inference request through a loopback-only spend
gate. The child receives only an ephemeral local capability; the actual Prime
key remains in the parent. The gate pins the priced model and chat-completion
route; rejects ambiguous HTTP framing, duplicate JSON keys, streaming,
conflicting or unbounded output, oversized requests, and cumulative reservations
above the run cap before forwarding; and retains only counts and costs. If the
provider reports usage beyond a request's reservation, the gate latches closed
for the rest of the run and the publication validator rejects the result:

```sh
Evals/marginbench/prime_pilot.py \
  --margin-bin build/margin --model qwen/qwen3.7-flash \
  --scenario agent_agent_handoff --max-tokens-per-call 2400 \
  --input-token-ceiling-per-call 1000000 \
  --input-price-per-million 0.03 --output-price-per-million 0.13 \
  --max-cost-usd 2.50 --live-proxy-cost-cap-usd 0.05 \
  --candidate CANDIDATE_ID \
  --summary-file SUMMARY.json --run-manifest-file RUN.json
```

For a frozen comparison, pass `--candidate-manifest CANDIDATE.json` so the
wrapper refuses a binary or candidate-ID mismatch. `--repetition-id N` selects
the exact planned case instead of implicitly starting at zero; the flag may be
repeated. Private runs additionally take `--holdout-key-file KEY`. The file must
be a regular mode-0600 file. Its value is placed only in the evaluation
taskset's environment and is consumed before any agent subprocess starts; the
dry plan and public result contain only its one-way key ID.

`--input-token-ceiling-per-call` must come from the provider/model contract. It
is deliberately separate from Verifiers' `max-input-tokens`: Verifiers counts a
deduplicated conversation graph and checks it between turns, while the provider
bills the complete prompt on every call. The wrapper multiplies the asserted
per-call ceiling by every permitted turn and by an SDK-retry allowance, then
adds a per-call billing-rounding allowance. `--max-cost-usd` is both the
conservative static admission cap and, by default, the cumulative reservation
cap enforced by the local proxy. `--live-proxy-cost-cap-usd` may make the live
cap smaller, while `--live-proxy-max-request-bytes` bounds the complete encoded
request. The proxy records its independently checkable policy and counters in
the redacted summary and run manifest. Alibaba's current model table documents
the example model at one million tokens:
https://help.aliyun.com/zh/model-studio/text-generation-model/ . Replace that
number only with a provider-published bound for the chosen model.

Thinking models require a second, separate contract. `max_tokens` bounds the
visible answer for Qwen 3.7, while the provider can report hidden thinking in
the same billable completion total. `--provider-reasoning-token-ceiling` names
that hidden ceiling, and `--provider-reasoning-token-ceiling-source` records the
HTTPS model contract supporting it. The spend gate inserts the corresponding
`thinking_budget` into the exact upstream request and reserves visible output,
hidden reasoning, and the small wrapper allowance before forwarding. For
`qwen/qwen3.7-flash`, the controllers freeze 4,000 tokens as a conservative
MarginBench study ceiling. That value is harness policy, not a claimed provider
default; Alibaba documents that the non-standard `thinking_budget` parameter
applies to the Qwen 3.7 series in its
[OpenAI-compatible API contract](https://help.aliyun.com/en/model-studio/qwen-api-via-openai-chat-completions).
No ceiling is guessed for unknown models. `--provider-response-token-allowance`
is only for a few provider accounting or wrapper tokens; it is not a hidden
reasoning budget.

Prime documents `max_tokens` as the maximum generated response and returns
completion usage through its OpenAI-compatible endpoint. A provider response
outside the complete reserved bound is therefore an infrastructure incident,
not a model score. See [Prime's chat-completion contract](https://docs.primeintellect.ai/api-reference/inference-chat-completions).

Before a reasoning-model study can execute, run the provider-contract probe.
It uses one fixed public prompt, one non-retrying request, no agent process, and
the same local spend proxy as the study. Dry-run is the default:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Evals/marginbench \
python3 Evals/marginbench/provider_contract_probe.py \
  --model qwen/qwen3.7-flash \
  --input-token-ceiling 1000000 \
  --input-token-ceiling-source https://help.aliyun.com/en/model-studio/text-generation-model/ \
  --input-price-per-million 0.03 \
  --output-price-per-million 0.13 \
  --pricing-source https://docs.primeintellect.ai/api-reference/inference-models
```

The current defaults reserve at most $0.00097682 and hard-stop at $0.001. A
live invocation additionally requires `--output`, `--execute`, and the literal
confirmation printed by `--help`. It stores only status, usage counts, checks,
and account-wide wallet movement—never credentials, prompt text, or response
text. A passing receipt is valid for 24 hours, is frozen by digest into the
study, and must be supplied with `--provider-contract-receipt`. HTTP success
shows only that the gateway returned success for a request containing the
parameter. It does not prove that an intermediary preserved it or that the
provider will enforce it forever, so every later study request remains
independently bounded.

The printed plan must be reviewed before adding the separately documented paid
execution flags. Raw traces remain under ignored `runs/`; only redacted summaries
and run manifests are publication artifacts.

The first real-provider proxy smoke is tracked as
`results/prime-live-budget-proxy-smoke-v1-public-r0-{summary,run}.json`. It
completed safely at 96.25: six requests forwarded, zero rejected, $0.008847
reserved beneath a $0.02 live cap, and $0.001 observed wallet debit. The smoke
is implementation evidence, not a statistically meaningful candidate result.

For a complete paired study, use the source package's `paired_pilot.py` instead
of launching forty independent jobs by hand. It is also dry-run by default:

```sh
Evals/marginbench/paired_pilot.py \
  --study-plan study-plan.json --execution-plan execution-plan.json \
  --baseline-manifest candidate-baseline.json --baseline-bin margin-baseline \
  --candidate-manifest candidate-new.json --candidate-bin margin-new \
  --holdout-key-file .private-marginbench/holdout.key \
  --model qwen/qwen3.7-flash \
  --input-token-ceiling-per-call PROVIDER_DOCUMENTED_LIMIT \
  --input-token-ceiling-source https://provider.example/model-contract \
  --input-price-per-million 0.03 --output-price-per-million 0.13 \
  --pricing-source https://provider.example/model-pricing \
  --live-proxy-cap-per-job-usd 0.05 \
  --max-study-cost-usd 4 --minimum-wallet-reserve-usd 190
```

The resulting `urn:marginbench:prime-study-plan:v1` artifact contains no secret
or local path. It binds all 72 candidate-ordered jobs, benchmark and candidate
digests, every limit and price, each job's unproxied contract bound and enforced
proxy cap, both aggregate bounds, and the protected reserve. With the values
above, the full unproxied contract maximum remains visible in the plan, while
the enforceable 72-job maximum is $3.60 and the first matched pair is $0.10.
Paid execution additionally needs the literal
confirmation printed by `--help`. `--max-new-jobs 1` stops cleanly after one
newly completed job; a later identical invocation resumes at the next job.
Completed outputs are schema- and digest-checked before a receipt is written.
An incomplete or uncertain attempt leaves a durable marker and blocks automatic
retry. After all jobs finish, the controller creates and independently verifies
the same redacted leaderboard bundle as the no-model reference runner.

Prime's current model record for `qwen/qwen3.7-flash` publishes its token prices,
and Alibaba's official model table documents its one-million-token context.
That verified number may replace `PROVIDER_DOCUMENTED_LIMIT`; however, the full
default paired study's deliberately pessimistic static bound is still about
$96.66. The live proxy is a second fail-closed boundary, not permission to
silently replace that published static assumption with observed low usage. Dry
planning, fake-child resumption tests, and publication verification require no
model call.

### Prime-managed runtime probe

The model-free development matrix uses local subprocesses. Before claiming the
same package works in Prime-managed infrastructure, use the separate sandbox
probe. It uploads the pinned Linux executable, runs a real typed comment write,
validates the resulting Markdown, and tears the sandbox down without calling a
model:

```sh
Evals/marginbench/remote_runtime_probe.py \
  --margin-bin Evals/marginbench/marginbench/bin/margin-linux-x86_64
```

Dry-run is the default. The plan reports both the expected two-minute cost and
the deliberately pessimistic cost if cleanup and the one-minute idle timer both
failed until Prime's 24-hour backend lifetime limit. Execution additionally
requires the literal confirmation printed by `--help`. Prime's published
sandbox rates are supplied as explicit flags and recorded so a future price
change cannot silently alter the estimate.

## Candidate hill climbing

A candidate is a precise bundle: Margin executable digest, manual digest, and
settings digest. Compare it to the baseline on identical episode IDs. Promotion
requires:

1. no safety or source-integrity regression;
2. a positive lower bound on the paired bootstrap confidence interval;
3. disclosed model, harness, task version, limits, retries, cost, and latency;
4. confirmation on private rotating cases, not only public development cases.

Use `marginbench compare BASE_RESULTS CANDIDATE_RESULTS` for the deterministic
paired comparison. Each side may be a result set, reference run, redacted Prime
summary, or redacted run manifest, so paid evidence needs no conversion or raw
trace access. Promotion requires at least 20 matching episodes by default,
a positive paired-bootstrap lower bound, and a candidate that is safe and
source-preserving on every case; a single
development case can diagnose a failure but can never be labeled promotable.
CLI/manual changes, model changes, team-layout changes, and prompt changes
should be reported as separate tracks rather than mixed into one claim.

`marginbench controls` publishes the frozen control catalog. Every unfinished
profile includes stable, machine-readable `blockingGates`, so automation can
show what evidence is still missing without attempting a run. The primary
role-separated Margin profile and the compute-matched single continuing-agent
profile are runnable. Plain-Markdown, Margin-plus-shell, and no-exchange
controls remain specified but fail closed until their task-neutral scoring or
isolation requirements are implemented. This prevents an attractive but
incomparable control result from quietly entering the main track.

Before model execution, freeze the paired cases and counterbalanced candidate
order without exposing prompts or answers:

```sh
marginbench study-plan --baseline released --candidate compact-guidance \
  --repetitions 4 > study-plan.json

marginbench execution-plan study-plan.json > execution-plan.json
```

`--control-profile single-agent-margin-v1` produces a static, executable plan
that records one model process and trace seat `agent` per episode while
retaining every logical author/reviewer role and summing their compute limits.
Reference and paid runners validate that topology; paid execution remains dry
by default and separately confirmation-gated. Planning the other cataloged
profiles is allowed for review, but execution rejects them before credentials,
output, or spend until their release gates are complete.

The continuing-agent implementation includes a trusted phase-identity file.
The controller can advance only through the frozen role order, publishes each
actor atomically with mode `0600`, and is read by the Margin tool server instead
of accepting identity from model arguments. Core and live MCP-server tests prove
out-of-order/replayed/concurrent advances fail and that one running tool server
switches from author to reviewer. A promptless continuing interaction now sends
the original role briefs as separate turns, retains one transcript, serializes
same-phase roles in generated order, and preserves scripted-event boundaries.
Both permanent in-process and environment-server fake-model matrices cover all
nine scenarios at 100 with one trace per actual model process. Live plans
sum the logical-role limits onto the one continuing process, preserve each
logical actor separately from the `agent` trace seat, and validate topology and
pricing. The profile is implemented.

The low-level paid pilot accepts one continuing-agent scenario family per
invocation (or several families only when they have the same logical-role
count), because Verifiers applies one process limit to the whole invocation.
The paired-study controller already launches one frozen case per child job and
therefore applies the exact summed limit automatically.

Four repetitions across all nine workflows produce the default 36 matching
episodes, exceeding the 20-episode promotion minimum. The execution plan
deterministically flattens each study pair into 72 candidate-ordered jobs,
preserving the exact 18 AB / 18 BA order and assigning every job a digest-derived
retry identity. Its default
failure rule stops after an incomplete job; a completed job is verified and
skipped on replay rather than charged twice. Supplying `--key-file` to the
study planner marks the plan as a private holdout; either emitted file contains
only fingerprints and role names, never the key, fixture text, prompts, or
oracle.

Before paying for agents, exercise the complete paired pipeline with the
deterministic reference policy. This follows every scheduled candidate job,
uses the real binaries and Margin gateway, scores both sides, writes redacted
run manifests and a paired comparison, then creates and re-verifies the whole
leaderboard bundle atomically:

```sh
marginbench reference-study reference-publication \
  --study-plan study-plan.json --execution-plan execution-plan.json \
  --baseline-manifest candidate-baseline.json --baseline-bin margin-baseline \
  --candidate-manifest candidate-new.json --candidate-bin margin-new
```

The output path must not already exist. Private studies also require
`--key-file`; public-development studies reject that flag so a mismatched key
cannot silently generate different cases. This command invokes no model and
reports `paidModelsInvoked:false`.

Create a rotating private key without placing its value in shell history or
stdout:

```sh
mkdir -p .private-marginbench
marginbench keygen .private-marginbench/holdout.key
```

The command creates a new mode-0600 file and refuses to overwrite any existing
path. Its JSON receipt contains only a one-way key ID. Keep that directory out
of version control and pass the file only to the task generator, never to an
agent runtime or public result.

## Public benchmark policy

- Public development seeds, schemas, reference policies, and scoring code are
  open for debugging.
- Leaderboard test keys and instantiated fixtures remain private and rotate
  after suspected exposure.
- Submissions identify every binary and setting by digest and disclose retries.
- A result with a failed integrity or workspace-policy check is capped at 25,
  regardless of partial task completion.
- Raw transcripts are not required for public submission. A redacted run
  manifest, aggregate usage, and digest-identified candidate bundle are.
  Cryptographic submitter signatures are not part of v1 and must not be
  implied by a checksum alone.

In a full Margin source checkout, the expanded benchmark card and known
limitations are in `Docs/MARGINBENCH.md`, and the build and spending ledger is
in `Docs/MARGINBENCH_PLAN.md`. Those source-tree records are not required by the
standalone package. The paid-wrapper cost-bound correction is preserved here in
`results/COST_BOUND_AUDIT.md` in the source archive.

The package is ready for Prime's Environment Hub, but a private upload under the
current OpenProse team requires that team to have a registry handle. This account
setting does not block local development, Prime Inference, or reproducible wheel
and source-package builds.
