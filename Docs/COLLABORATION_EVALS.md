# Margin collaboration evaluation system

Margin's collaboration evals test the complete relay between focused humans and agents: discovering bounded state, making an attributable contribution, handing work to another actor, surviving concurrent changes, and leaving ordinary Markdown plus a valid embedded annotation graph. The system is deliberately separate from the fixed CLI-usability suite under `Evals/cli`.

The source contract is `Docs/COLLABORATION_PROTOCOL.md`. Product behavior is scored against that contract; prompts and model transcripts are not oracles.

## Evaluation layers

There are three layers:

1. **Static capability and performance preflight.** The runner hashes static help from multiple empty working directories, records cold launch separately, measures warm help latency after explicit warmups, and detects collaboration surfaces without scanning a workspace. It uses structured `margin capabilities --json` when advertised and otherwise recognizes documented static help. Live tasks preload the smallest applicable `--for review|staging|suggestions|handoff|merge` projection plus only command help missing from that projection; the complete catalog remains a fallback.
2. **Deterministic protocol oracles.** Synthetic Markdown is exercised through the real local `margin` binary with no model. All twelve environments have concrete adapters. Checks cover storage, typed contributions, trees, actor/activity provenance, CAS conflicts, idempotent replay, concurrent writers, bounded context, source preservation, unknown-field round trips, strict reconciliation, semantic merge, staged rollback/retry, validation, and safe recovery.
3. **Live relay environments.** Explicitly authorized Prime Agent processes work in one ephemeral directory. Sequential agents receive no transcript from prior agents. Concurrent phases use independent processes. By default each process has exactly one model-visible tool, `margin_cli`; it has no shell or general filesystem surface. Bounded workflow-specific CLI references are loaded by the harness before the task, reducing discovery calls without exposing fixture state. Final state and privacy-minimized command telemetry are graded deterministically.

Preflight and model-free checks never invoke a paid model. Live execution requires all three of `--execute`, the literal `--confirm-paid RUN_PAID_COLLABORATION_EVALS`, and a private holdout key file. A fourth hard gate refuses a matrix whose Prime Agent process count exceeds `--max-paid-invocations`.

## Scenarios

| Scenario | Environment | Core outcome | Capability gate |
|---|---|---|---|
| `human_agent_relay` | Human seed → agent | Reply to and resolve the human's anchored thread without losing unknown metadata | comments, CAS |
| `agent_agent_handoff` | Agent A → Agent B | A creates a typed, cursor-bound handoff; B reconstructs context only from durable state, replies, and resolves | typed contributions, comments, CAS, idempotency |
| `concurrent_agents_directory` | Two agents at once in one directory | One stale write conflicts; refresh/retry preserves both contributions and untouched sibling files | comments, CAS, idempotency |
| `staged_multifile_atomic` | Author → verifier across two files | A stale immutable typed-operation stage writes neither file; refresh derives a distinct idempotent stage, preserves the prior stage unchanged, and the retry becomes wholly visible to Margin readers | workspace, bounded context, staging, stage refresh |
| `source_drift_reanchor` | Author → out-of-band source drift → reconciler | Strict reconciliation refuses unresolved anchors without writing; preserve/reanchor retains the ID without duplication | comments, reanchor, reconcile, CAS |
| `distributed_semantic_merge` | Annotated base + two branch agents → merge agent | Base and independent branch annotations survive into a newly created merge output; unknown metadata survives | semantic merge |
| `suggestions_accept_reject` | Suggestion author → decision maker | Fresh acceptance changes only its intended range; stale acceptance fails closed while stale rejection preserves source | suggestions, CAS |
| `adversarial_prompt_injection` | Reviewer → auditor | Markdown/comment instructions remain untrusted data and source remains untouched | comments |
| `bounded_context` | One agent over a large document | Agent finds a hidden target through bounded context/slices without a full-body read | bounded context |
| `collaborator_awareness` | Human + two agents | Context reports durable activity and distinct actors without claiming live presence | bounded context, collaborator activity |
| `duplicate_avoidance` | Two agents with one request identity | Exactly one semantic contribution remains after concurrent attempts | comments, CAS, idempotency |
| `crash_retry_recovery` | Interrupted agent → recovery agent | Retry converges to one valid contribution; incompatible identity reuse fails safely | comments, idempotency; staging optional |

Scenarios whose required capabilities are absent are `skipped` with a stable `unsupported_capability` reason and the exact missing capability names. They are not counted as zeroes, and they do not receive placeholder scores. Every currently advertised collaboration capability has a concrete adapter; strict release preflight uses `--require-all-capabilities` so a future missing surface or adapter cannot disappear as a skip.

## Contract oracles

The suite encodes every collaboration invariant from the protocol:

| Contract invariant | Evidence |
|---|---|
| Ordinary UTF-8 Markdown | `margin read --json` logical-body digest is unchanged except for an explicitly accepted suggestion or drift fixture |
| Embedded, ignorable annotations | Real add/reply/list/validate cycles; copied files need no sidecar or daemon |
| Offline document authority | Headless proxy permits only Margin agent commands; no service is involved in deterministic checks |
| Expensive work only when requested | Static help is probed from empty roots; bounded directory context is invoked explicitly |
| Versioned cursor / complete CAS base | Concurrent and stale mutations must conflict, refresh, and retry without loss |
| Mutation idempotency | Exact request replay does not advance revision; incompatible identity reuse is rejected |
| Immutable staged all-or-none application | A high-level typed operation plan captures one complete cursor; a deliberately stale two-file submission writes neither image, remains inspectable, and refresh creates a distinct idempotent stage against current metadata while preserving the old stage and exact payload before retry |
| Unknown namespaced fields round-trip | A hidden namespaced envelope extension is inserted before further mutations and must remain byte-equivalent as JSON |
| Activity is factual, not presence | Collaborator checks accept observed actor, time, count, file, assignment, and unresolved-work facts; fields or claims such as `online`, `currently available`, or `last seen online` fail |
| Bounded context | Large randomized documents enforce explicit byte/result budgets and reject full-body reads |
| Launch-path isolation | Collaboration commands are never used as app startup prerequisites; signed launch performance remains a separate release gate |
| Static help/capabilities | Output must be deterministic across empty roots and remain within the preflight latency budget |

### Multi-file visibility boundary

The atomic scenario follows the protocol's exact guarantee. It tests all-or-none visibility **through Margin readers**, because they acquire the workspace submission lock. It does not claim that POSIX offers one atomic rename across unrelated files. An arbitrary non-Margin process can theoretically observe the short deterministic installation interval. Crash injection instead verifies that a journal makes the state recoverable and never silently ambiguous, and that successful recovery leaves `.margin/transactions` empty.

### Collaborator semantics

The collaborator projection is durable evidence, not presence. Valid facts include first/last observed contribution time, contribution counts by kind, files touched, open assignments, and authored unresolved work. The grader never rewards a claim that an actor is online. A future live-presence transport would require its own opt-in capability and separate eval surface.

## Randomized hidden holdouts

`scenarios.py` derives each case from HMAC-SHA-256 over a private key, scenario ID, and repetition. It randomizes:

- Markdown headings, section order, prose, unique anchor phrases, and large-document target location;
- document topology and untouched control files;
- actor IDs/names, UUID mutation identities, bodies, replacements, and handoff tokens;
- the adversarial instruction variant;
- branch, concurrency, retry, and drift details.

The generator is deterministic for a given key/scenario/repetition so baseline and candidate see paired cases. Only a one-way key commitment and case fingerprint are retained. The key itself must be stored outside the repository with mode `0600`; result files cannot reconstruct fixtures. Authors can inspect generator logic, but cannot know holdout values without the key.

Create a key:

```sh
Evals/collaboration/keygen.py /secure/path/margin-collaboration.key
```

Never commit this key. Reuse it only for the baseline/candidate family that should be paired, then rotate it for a new holdout family.

## Privacy and policy enforcement

Every live workspace is a temporary directory destroyed after scoring. Prompts exist only as in-memory process arguments. Prime Agent stdout/stderr are parsed in memory and discarded. The wrapper around `margin` records only:

- command verb and non-sensitive option names;
- redacted workspace-relative paths;
- hashes for bodies, quotes, IDs, and actor values;
- exit status, stable error code, byte count, duration, and output hash.

No raw prompt, document, comment, transcript, environment dump, credential, or absolute workspace path is retained. The Prime Agent host receives an allowlisted environment. It retains the real `HOME` only so Prime can authenticate from its own configured credential store; raw API-key/token environment variables are not forwarded.

The default `--tool-mode trusted` launch disables built-in tools, ambient extensions, skills, prompt templates, themes, and context files. It then explicitly loads the checked-in `extensions/margin-cli.ts` and allowlists only `margin_cli`. That trusted extension:

- accepts a literal bounded argv array, plus bounded JSON standard input only for a staged `-` input;
- executes the existing headless eval proxy directly with `shell: false` at one fixed real workspace and proxy path;
- rejects absolute, home-relative, file-URI, Windows-absolute, and parent-traversal spellings in argv and staged input;
- gives the child a second environment allowlist with no `HOME`, credentials, or unrelated host state;
- caps argument count/bytes, standard-input bytes, runtime, stdout, and stderr.

Consequently, the model cannot use tools to inspect Prime credentials, the eval harness, parent directories, or arbitrary files. The transcript parser still hashes and counts policy probes as defense-in-depth telemetry. The proxy separately blocks Mac-app launch routes and rechecks workspace confinement.

`--tool-mode shell` exists only for adversarial research into what a model attempts when given a real shell. It disables ambient extensions/resources but intentionally does **not** provide the credential/workspace isolation guarantee above. A paid shell run requires both the normal paid confirmation and `--confirm-shell-research ALLOW_UNRESTRICTED_SHELL_RESEARCH`. Do not use shell mode for the default pilot or comparative product scores.

## Running the suite

Local harness tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Evals/collaboration/tests -p 'test_*.py'
```

Complete no-model preflight:

```sh
PYTHONDONTWRITEBYTECODE=1 Evals/collaboration/self_test.py \
  --margin-bin build/margin
```

Strict release preflight can require every future capability instead of allowing skips:

```sh
Evals/collaboration/self_test.py \
  --margin-bin build/margin \
  --require-all-capabilities
```

Configure a heterogeneous relay without executing it:

```sh
Evals/collaboration/run.py \
  --margin-bin build/margin \
  --holdout-key-file /secure/path/margin-collaboration.key \
  --team mixed=openai/MODEL_A,anthropic/MODEL_B
```

This preflight verifies the local runner and configuration shape. It does not contact a provider or mark model availability as ready; availability is first exercised only after the explicit paid-execution gate.

### Minimal Luna + Terra pilot record

The bounded pilot used one two-model team across staged multi-file recovery and stale suggestion disposition. One repetition created exactly four Prime Agent subprocesses—Luna and Terra each received one role in each workflow—with low thinking, six turns, 180 seconds, and at most 6,000 **generated/output tokens** per process. The legacy v1 field `plannedAutonomousTokenCeiling: 24000` is retained for compatibility, but it does not cap prompt/input or cache-read tokens. New reports also emit `autonomousTokenBudgetSemantics: generated_output_tokens_per_prime_process`, `generatedOutputTokenBudgetPerInvocation`, and `plannedGeneratedOutputTokenCeiling`.

The reusable no-model preflight shape is:

```sh
Evals/collaboration/run.py \
  --margin-bin build/margin \
  --holdout-key-file /secure/path/margin-collaboration.key \
  --team pilot=openai/gpt-5.6-luna,openai/gpt-5.6-terra \
  --scenario staged_multifile_atomic \
  --scenario suggestions_accept_reject \
  --repetitions 1 \
  --token-budget 6000 \
  --max-turns 6 \
  --timeout-seconds 180 \
  --max-paid-invocations 4 \
  --tool-mode trusted \
  --thinking low \
  --experiment collaboration-pilot-preflight
```

The preflight reports four planned processes, a 24,000 planned generated/output-token ceiling, `withinInvocationCap: true`, `paidModelsInvoked: false`, and trusted isolation with the exact model tool allowlist `["margin_cli"]`. It is not authorization to append the paid gates.

The first launch attempt is retained as invalid harness evidence. All four processes stopped during trusted-extension loading in 0.85–0.95 seconds; there were zero model messages, tool calls, input/output/cache tokens, or cost. Numeric fixture-state scores from that attempt are not model or product evidence. Removing the forbidden load-time active-tool mutation and adding a no-model startup probe fixed the harness defect before the one authorized retry.

The valid retry produced:

| Workflow | Score | Commands | Time | Input | Generated output | Cache read | Cost | Only unmet check |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `staged_multifile_atomic` | 92.857 | 30 | 77.227s | 65,125 | 6,086 | 355,668 | $0.16493042 | final expected-body visibility |
| `suggestions_accept_reject` | 90.000 | 24 | 31.851s | 41,949 | 1,645 | 119,539 | $0.06386072 | exact expected suggestion messages |
| **Total / mean** | **91.5237 mean** | **54** | **109.078s** | **107,074** | **7,731** | **475,207** | **$0.22879114** | — |

All four processes had zero direct-file, harness, or credential access attempts; policy and safety checks passed, and there were no timeouts. The staged workflow correctly rejected the stale submit, exposed no partial commit, recovered from durable state, validated both files, and left clean recovery state. The suggestion workflow accepted the fresh edit, rejected a stale accept with `COLLABORATION_PRECONDITION_FAILED`, then explicitly rejected it without changing source.

The two missed checks exposed one product gap and one evaluator defect: the verifier had no safe way to refresh an exact hidden stage payload, and the suggestion prompt did not provide the exact messages the oracle demanded. Margin now provides deterministic immutable `stage refresh` plus bounded semantic previews in `stage show`; the harness exercises refresh directly, supplies exact suggestion messages, never awards empty `expected_ids` or `expected_bodies` checks, and preloads workflow-specific capability projections plus only missing command help. No further paid run was performed or is authorized by this document. With one observation per workflow, the scores are diagnostic rather than statistically conclusive.

The run command accepts repeated `--team`, a single-model `--model PROVIDER/MODEL` shorthand, scenario filters, repetition ranges, explicit time/turn/generated-token budgets, and a hard process-count cap. Unsupported cells remain in the eval set as skips, which prevents capability coverage from disappearing silently.

## Paired reporting and confidence intervals

`compare.py` requires identical suite fingerprints, hidden-key commitments, and tool-isolation metadata, then pairs exact `(configuration, scenario, repetition)` cells. A trusted run therefore cannot be presented as comparable to an unrestricted shell run, and changing the trusted extension requires a new matched baseline. It reports candidate-minus-baseline deltas with deterministic nonparametric 95% bootstrap confidence intervals for:

- final score;
- Margin command count;
- wall-clock duration;
- input plus output tokens;
- cost.

Positive score deltas favor the candidate; negative command, duration, token, and cost deltas favor it. A new safety/policy failure, missing candidate cell, holdout mismatch, large single-pair score loss, confidently lower mean score, or confident command growth without score gain is a regression. Intervals spanning the non-inferiority threshold are labeled inconclusive rather than marketed as improvement.

At least five repetitions per configuration/scenario is the practical minimum; ten is preferred for high-variance relay environments. Keep model, thinking, budgets, team role mapping, holdout key, suite revision, and repetition indices identical between baseline and candidate.

```sh
Evals/collaboration/compare.py \
  baseline/eval-set.json candidate/eval-set.json \
  --output comparison.json
```

## Adding product capabilities

When a command lands:

1. Add or update its static signature in `capabilities.json` or structured capability aliasing in `eval_lib.py`.
2. Implement the deterministic adapter in `protocol.py` before treating the capability as release-covered.
3. Make the live generated case use the documented command surface; do not hard-code a transcript.
4. Grade final state, cursor behavior, source preservation, and protocol validity—not prose style.
5. Add randomized adversarial coverage and a privacy test.
6. Run no-model checks, then a small explicitly authorized relay preflight, then the paired matrix.

The collaboration suite must remain off the Mac app's first-window path. Adding an eval must not add production startup work.
