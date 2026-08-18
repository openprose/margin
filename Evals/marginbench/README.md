# MarginBench

MarginBench measures whether agents can collaborate with a human and with one
another through durable Markdown state. It runs real Margin commands in an
isolated workspace and scores the resulting files. It does not ask another
model to judge the transcript.

The benchmark is provider-independent. `marginbench/` contains the generator,
gateway, runner, scorer, and candidate comparison code. `marginbench.prime` is
the first hosted adapter, built for Prime Intellect Verifiers v1.

## What v1 measures

The six current scenario families cover:

- replying to and resolving a human's existing review thread;
- leaving a durable handoff that a second agent can find without a transcript;
- two agents writing concurrently without losing or duplicating work;
- proposing two exact source changes and accepting one while safely rejecting
  the other after its source cursor becomes stale;
- staging one all-or-none change across two files, observing stale metadata,
  refreshing the immutable stage, and submitting it atomically.
- triaging a human thread in one directory document, leaving a typed handoff in
  another, and having a second agent discover and complete it from root context
  without receiving the first agent's transcript.

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
make marginbench-preflight
```

`marginbench-test` runs the Python contracts under both the system interpreter
and Prime's Verifiers environment, then requires the deterministic reference
policy to score 100 on every scenario. `marginbench-preflight` runs every role
in all six Verifiers v1 scenarios through a local fake OpenAI-compatible model,
first in process and then across Prime's real environment-server boundary.
Neither command invokes a paid model. CI also repeats the served path with a
fresh private key, publishes only its one-way key ID, then overwrites and deletes
the key in the same job. A public preflight ignores any ambient holdout-key
variable unless `--holdout-key-file` was explicitly supplied.

The same gates are encoded in `.github/workflows/marginbench.yml` for a clean
Ubuntu runner. The workflow has read-only repository permissions, uses no
secrets or paid service, rebuilds the published x86-64 binary against its
tracked digest, runs the Prime fake-model rehearsal, exercises the wheel inside
the pinned Swift/Linux image, and retains only the package plus a redacted
validation receipt.

Individual commands are also available:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli generate \
  --scenario human_agent_relay --repetition 0

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli reference \
  --margin-bin build/margin --scenario concurrent_review

PYTHONPATH=Evals/marginbench python3 -m marginbench.cli self-test \
  --margin-bin build/margin
```

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
route, rejects streaming, unbounded output, oversized requests, and cumulative
reservations above the run cap before forwarding, and retains only counts and
costs:

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
  --max-study-cost-usd 3 --minimum-wallet-reserve-usd 190
```

The resulting `urn:marginbench:prime-study-plan:v1` artifact contains no secret
or local path. It binds all 48 candidate-ordered jobs, benchmark and candidate
digests, every limit and price, each job's unproxied contract bound and enforced
proxy cap, both aggregate bounds, and the protected reserve. With the values
above, the one-million-token contract maximum remains visible as $96.662016,
while the enforceable 48-job maximum is $2.40 and the first matched pair is
$0.10. Paid execution additionally needs the literal
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

`marginbench controls` publishes the frozen control catalog. The primary
role-separated, Margin-only profile is runnable. Single-context, plain-Markdown,
and Margin-plus-shell controls are specified but fail closed until their
identity, task-neutral scoring, and disposable-sandbox requirements are
implemented. This prevents an attractive but incomparable control result from
quietly entering the main track.

Before model execution, freeze the paired cases and counterbalanced candidate
order without exposing prompts or answers:

```sh
marginbench study-plan --baseline released --candidate compact-guidance \
  --repetitions 4 > study-plan.json

marginbench execution-plan study-plan.json > execution-plan.json
```

Four repetitions across all six workflows produce the default 24 matching
episodes, exceeding the 20-episode promotion minimum. The execution plan
deterministically flattens each study pair into 48 candidate-ordered jobs,
preserving the exact 12 AB / 12 BA order and assigning every job a digest-derived
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

The benchmark card and known limitations are tracked in
[`Docs/MARGINBENCH.md`](../../Docs/MARGINBENCH.md). The build and spending ledger
is [`Docs/MARGINBENCH_PLAN.md`](../../Docs/MARGINBENCH_PLAN.md). The paid-wrapper
cost-bound correction is preserved in
[`results/COST_BOUND_AUDIT.md`](results/COST_BOUND_AUDIT.md).

The package is ready for Prime's Environment Hub, but a private upload under the
current OpenProse team requires that team to have a registry handle. This account
setting does not block local development, Prime Inference, or reproducible wheel
and source-package builds.
