# MarginBench benchmark card

Version: 0.1 development snapshot

Primary artifact: `Evals/marginbench`

First hosted adapter: Prime Intellect Verifiers v1

## Purpose

MarginBench evaluates a specific claim: an agent should be able to collaborate
with humans and other agents through documents without needing a private chat
transcript or an unstructured shared shell. The shared record must stay correct,
portable, attributable, and understandable after processes disappear.

This is not a general writing-quality benchmark. V1 measures correct use of
Margin's Markdown collaboration protocol: bounded reads, threaded comments,
typed handoffs, directory-wide discovery, suggestions, concurrent updates, and
atomic multi-file stages.

## Why the core is ours and Prime is an adapter

Prime is a strong fit for the evaluation and training layer. Its environment
model is the same shape MarginBench needs—task data, a multi-turn tool harness,
and executable scoring—and one environment can drive local evaluation, hosted
evaluation, and reinforcement-learning rollouts. Prime's Hub distributes these
environments as versioned Python wheels. See Prime's official descriptions of
the [environment model](https://docs.primeintellect.ai/hosted-training/environment-model),
[Verifiers environments](https://docs.primeintellect.ai/verifiers/environments),
and [Environment Hub packaging](https://docs.primeintellect.ai/tutorials-environments/create).

The benchmark core nevertheless remains provider-independent. Episode
generation, the Margin gateway, exact scorer, schemas, and candidate comparison
run without Prime or a model account. That keeps the public benchmark auditable,
lets contributors reproduce it in ordinary Linux containers, and allows future
adapters for other inference or training systems. The same separation also
keeps provider code entirely off Margin's application and CLI startup paths.

Hosted training is a credible later hill-climbing route once the evaluation
surface is stable: Prime documents that Verifiers environments plug directly
into its managed evaluation and LoRA reinforcement-learning system. That is a
reason to preserve the adapter, not to couple MarginBench's protocol or public
governance to one vendor. See [Prime Lab](https://docs.primeintellect.ai/hosted-training/what-is-lab)
and [training with Verifiers](https://docs.primeintellect.ai/verifiers/training).

## Unit of evaluation

An episode contains a generated Markdown workspace, one or two role-specific
briefs, optional scripted human or external events, and a hidden executable
oracle. Agents receive their own brief and one confined Margin tool. Sequential
roles do not receive one another's transcript. Concurrent roles operate against
the same files and lock state.

The initial task families are:

| Family | Collaboration pressure | Required durable result |
| --- | --- | --- |
| Human relay | Human → agent | Exact reply in the existing thread, followed by a verified resolution |
| Agent handoff | Agent → agent | Typed durable handoff, later discovery, reply, and resolution without transcript sharing |
| Concurrent review | Agent ↔ agent | Both contributions survive, with correct authorship and no duplicates |
| Suggestion decision | Author → reviewer | Two exact proposals; one accepted source edit and one stale-safe rejection |
| Staged multi-file | Author → human event → reviewer | Stale attempt changes nothing; refreshed stage commits both files or neither |
| Directory handoff | Human → author → reviewer | Triage in one file and a discoverable, completed handoff in another without transcript sharing |

Cases are deterministic for `(version, private key, family, repetition)`. The
key changes the prose, identities, IDs, and exact outcomes while preserving task
difficulty and scorer behavior.

## Score

The total score is deterministic and weighted:

- 45% exact outcome;
- 20% document and transaction integrity;
- 15% protocol use and attribution;
- 10% required recovery behavior;
- 10% bounded command efficiency.

The scorer reads final documents through Margin and checks exact annotation
identity, body, kind, status, creator, source hashes or required source changes,
validity, duplication, all-or-none groups, required command paths, expected
conflict codes, and gateway violations. It never asks a model to judge another
model.

If source integrity, document validity, atomicity, or workspace confinement
fails, the total is capped at 25. Empty expected sets do not award task credit:
scenario-specific outcome checks are always populated and tested against an idle
agent.

## Security and privacy

The gateway is the only agent-facing tool. It binds identity, rejects paths
outside the workspace, blocks GUI routes and non-Margin commands, limits
arguments/stdin/output/time, and provides no shell. All collaborators in one
episode share the same Margin lock directory so concurrency behavior matches a
real shared workspace.

The privacy-minimized event log contains command names and measurements, not
arguments, bodies, document paths, or prompts. Provider-generated raw traces are
more sensitive because they contain prompts and tool output. They are ignored,
kept only long enough to diagnose a run, and never required in a public result.

A served Prime task carries only public selection fields and a one-way case
fingerprint. The trusted environment regenerates the fixture and oracle from its
private key, rejects any fingerprint mismatch, and then gives each agent a plain
role task without the hidden episode attached. This is tested through Prime's
actual server-side task reconstruction path, not only by inspecting local JSON.
Prime's client must retain the key just long enough for the trusted environment
worker to inherit it. That worker reconstructs and verifies the hidden episode,
then removes the key from its environment before resolving Margin, creating the
workspace, starting the tool gateway, or starting an agent. Both the in-process
and separate-worker paths complete all six private fake-model cases at full
score; CI creates and destroys a new key for the served-path check.

Document and comment text is untrusted collaborative content. Prompts explicitly
state that it cannot override the user's request, tool policy, or system rules.

## Reproducibility

A valid result records:

- benchmark and task-set version;
- scenario IDs and public fingerprints;
- model/provider identifier;
- harness and runtime;
- role layout and concurrency;
- Margin binary, manual, and settings digests;
- turn, token, timeout, output, and command bounds;
- retry policy;
- per-episode scores and safety checks;
- aggregate latency, token use, and cost;
- whether cases used the public development key or a private holdout.

Provider cost needs two distinct numbers. The expected planning figure may use
prior observed calls, but the pre-run admission bound must assume the largest
billable prompt permitted on every possible call, every allowed response, SDK
retry attempts, and billing rounding. Verifiers' `max_input_tokens` is not that
bound: it limits a deduplicated message graph and is checked between turns,
whereas inference billing counts each full prompt again. MarginBench therefore
requires a separately verified provider/model input ceiling per call and records
the complete basis of the cost bound.

The Linux Margin executable is built from the same source as the macOS app using
a pinned multi-architecture Swift container. The binary itself is a release
artifact rather than a Git object; its digest and byte size are recorded.

The tracked `MarginBench` continuous-integration workflow starts from an empty
Ubuntu runner with read-only repository permission. It repeats all portable
Swift tests, rebuilds the x86-64 binary against its declared digest, runs the
provider-independent and Prime adapter contracts, completes the fake-model
six-workflow rehearsal both locally and across Prime's environment-server wire,
repeats that served rehearsal with a fresh private key, builds the wheel,
exercises it in the pinned Linux image, and retains the package with a validation
receipt. The key is overwritten and deleted in the same job. It has no external
credential or paid-inference step. The workflow file is statically checked
locally; its first hosted execution awaits a GitHub remote.

Public JSON evidence can be checked independently with `marginbench validate`.
The installed command bundles all versioned schemas and adds bounded semantic
checks for totals that JSON Schema alone cannot prove: event counts, episode
identity, candidate digests, counterbalancing, promotion rules, role-run usage,
wallet reconciliation, and paid-run admission bounds. It reads no more than
16 MiB, rejects duplicate keys and non-finite numbers, makes no network call,
and returns a machine-readable validation receipt with a SHA-256. A receipt is
evidence that bytes satisfy the published rules; it is not a submitter
signature.

For leaderboard publication, `marginbench submission create` adds the missing
cross-file guarantee. Its deterministic manifest binds both candidate
manifests, the study plan, its exact candidate-ordered execution plan, all
redacted run manifests, and the reported paired comparison by SHA-256.
`marginbench submission verify` then checks the complete
episode coverage for both candidates, benchmark/track/control identity,
candidate, per-episode build, and benchmark-implementation digests, study
fingerprints and promotion threshold, track-specific fixed execution settings,
safety and source integrity, and a fresh deterministic recomputation of the comparison. It reads
each artifact as one bounded snapshot, rejects paths outside the bundle and
symlink references, allows at most 16 MiB per artifact and 64 MiB in aggregate,
and requires no raw traces, prompts, fixtures, credentials, or holdout key.
The resulting receipt proves internal consistency of the published bytes; it
does not authenticate the submitter or prove the order in which candidates
were actually executed.

## Leaderboard tracks

Results should not collapse unlike interventions into one ranking:

1. **Model track:** fixed Margin binary, manual, tool surface, and team layout.
2. **Interface track:** fixed models and roles; compare Margin CLI/manual/settings bundles.
3. **Team track:** fixed models and interface; compare role assignment and coordination policy.
4. **Open-systems track:** any disclosed models, interface, prompts, and orchestration.

The primary comparison is paired: baseline and candidate see the same generated
episode IDs. A candidate is promotable only with at least 20 matching episodes,
safe and source-preserving behavior on every candidate episode, and a lower
bound above zero on a deterministic paired bootstrap 95% interval. Duplicate
episode IDs are rejected rather than silently collapsed. Public-development
gains must be confirmed on a private rotating test set.

The default study planner freezes four repetitions of all six workflows and
counterbalances candidate order to exactly 12 AB and 12 BA episodes. It emits
only case fingerprints, roles, and candidate order—not private prompts, answers,
or the holdout key. The deterministic execution planner expands those pairs to
48 ordered candidate jobs with digest-derived identities and fail-closed resume
rules. Prime can select each exact repetition rather than regenerating index
zero, and a frozen candidate manifest must match the executable. For private
runs, the taskset consumes the mode-0600 holdout key from its environment before
agent subprocesses start; only its one-way ID is published. The runnable primary
control is role-separated collaboration through Margin alone. Single-agent,
plain-Markdown, and Margin-plus-shell controls are specified publicly but refuse
to run until their identity, scoring, and isolation rules are implemented; they
cannot silently enter the main track.

The same schedule is exercised end to end without a model by
`marginbench reference-study`. It runs both frozen binaries through the real
gateway in candidate order, scores every case, creates the two redacted run
manifests and comparison, assembles the digest-bound publication directory,
and re-verifies it before atomically exposing the output. That makes scheduling,
candidate identity, private-key parity, scoring, comparison, and publication a
single zero-cost CI gate rather than separate assumptions.

The source package also includes `paired_pilot.py`, a dry-by-default controller
for the corresponding Prime study. It turns the entire execution schedule into
one immutable, schema-checked cost plan before any paid call. The plan binds the
two candidate bundles, generation-key ID, model, live limits, price inputs, each
job's worst-case charge, the whole-study cap, and a wallet reserve. Execution is
serial and receipt-based: completed jobs are revalidated and skipped on resume;
an attempt without complete trustworthy evidence stops for operator review and
is never retried automatically. `--max-new-jobs 1` provides a cheap first-job
gate before continuing the remaining schedule.

## Contamination policy

Public seeds and task generators are deliberately available for development, so
their scores are not holdout evidence. Official submissions use an unreleased
key, disclose the benchmark commit before evaluation, and receive only public
fingerprints. Test keys rotate between leaderboard windows and immediately after
credible leakage. Exact private fixtures, prompts containing generated answers,
and raw traces may not be used for training or prompt tuning.

Benchmark code and Margin code may be optimized freely against public cases.
Those changes must be frozen by digest before private evaluation.

## Licensing recommendation

Use Apache-2.0 for benchmark code and schemas so commercial and research users
can implement adapters while retaining notices and patent protection. Release
public development fixtures under CC BY 4.0. Do not license private test fixtures
for redistribution; publish only aggregate/redacted results and rotate any
fixture that becomes public. Model outputs remain governed by the relevant
provider and submitter terms.

The repository does not yet contain a top-level license, so this is a
recommendation, not a claim that those licenses already apply.

## Known limitations

- V1 has six scenario families and is not yet broad enough for a definitive
  model ranking.
- It measures protocol correctness more strongly than prose quality or creative
  judgment.
- The current local Prime adapter uses subprocess agent runtimes; public hosted
  role sessions still await Environment Hub publication. The packaged x86-64
  binary itself has passed a real no-model Prime-managed sandbox write and
  validation probe, with teardown verified.
- Linux preserves modes, locking, atomic writes, and recovery, but macOS-only
  ACL/xattr preservation is not yet guaranteed on Linux.
- A single deterministic sample is useful for debugging but not evidence of an
  interface improvement. Promotion requires repeated paired private cases.
- Provider rate limits and transient errors must be reported as infrastructure
  outcomes, never scored as model failures or silently retried as new episodes.
- Submission manifests prove that a published evidence bundle is internally
  consistent, but v1 has no submitter signature, transparency log, or trusted
  proof that the counterbalanced execution order was followed. Official intake
  must authenticate submissions and control private-case execution separately.
- The validator deliberately identifies four tracked historical artifacts as
  invalid instead of normalizing them away: the original experiment log reused
  a later ledger identifier with a different shape, two early handoff summaries
  contain duplicate episode IDs, and the staged summary exceeded the old
  nominal cost estimate. The corrected redacted run manifests and experiment
  ledger are valid. Keeping both the evidence and the explicit failure is part
  of the audit trail.

## Current evidence

At the current 0.1 development snapshot, all six reference scenarios score 100
on macOS, Linux x86-64, and Linux arm64. Margin 0.3.2 passes 164 macOS tests and
112 portable Linux tests; a repeat x86-64 build is byte-for-byte identical. The Verifiers v1
adapter completes the whole six-case local fake-agent matrix at 100 with only
one exposed tool. The installable manylinux wheel and source archive also pass
their tests in clean containers. The system Python runtime passes 37 benchmark
contracts with six Prime-only skips; Prime's runtime passes all 43. The wheel
bundles all 24 schemas.

Real Qwen Flash runs exercised the original five families; the new directory
handoff has deliberately only used no-model gates so far. The initial human-relay smoke
scored 25; successive general CLI guidance improvements reached the exact
durable result and then 100. Handoff reached 100. Concurrent review, suggestion
decision, and stale multi-file recovery all reached their exact final document
state, scoring 92.083, 89.821, and 92.5 because of extra or invalid command
attempts. These are useful interface failures, not hidden or discarded results.
The final CLI returns exact verification steps after typed contributions,
suggestions, and handoffs, addressing the remaining recurring syntax errors.
The complete phase used $0.0267, leaving $199.9594. Exact artifacts, all 13
attempts, and the historical cost-bound correction are kept in the tracked
results and build ledger.
