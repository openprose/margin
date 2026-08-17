# Margin collaboration evals

This suite measures whether humans and agents can coordinate through durable Markdown state, not whether a model can imitate a reference transcript. Fixtures, actors, mutation IDs, text, document structure, and adversarial instructions are generated from a secret holdout key for every scenario and repetition.

## No-model checks

Run the full capability probe and every currently supported deterministic protocol oracle:

```sh
PYTHONDONTWRITEBYTECODE=1 Evals/collaboration/self_test.py --margin-bin build/margin
```

Run harness tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Evals/collaboration/tests -p 'test_*.py'
```

Both commands are local and report `paidModelsInvoked: false`. All twelve advertised collaboration environments have deterministic adapters; use `--require-all-capabilities` for the release gate. Missing future product capabilities produce explicit scenario skips, and a detected capability without a safe adapter never receives a simulated pass.

## Live relay runs

Remote execution is triple-gated (`--execute`, literal confirmation, and a private holdout key), then bounded by a hard maximum Prime Agent invocation count. The default `--tool-mode trusted` disables Prime's built-in tools and ambient resources, explicitly loads the eval-local extension, and exposes only one fixed-workspace `margin_cli` tool. Create the key outside the repository and keep it for the matching baseline and candidate:

```sh
Evals/collaboration/keygen.py /secure/path/margin-collaboration.key
```

Preflight a proposed matrix without invoking a model:

```sh
Evals/collaboration/run.py \
  --margin-bin build/margin \
  --holdout-key-file /secure/path/margin-collaboration.key \
  --team same-model=openai/MODEL
```

The no-model preflight verifies the local Prime Agent executable and team syntax, but deliberately does not query providers or claim that a configured model is available.

Only after reviewing preflight, explicitly authorize a live run:

```sh
Evals/collaboration/run.py \
  --execute \
  --confirm-paid RUN_PAID_COLLABORATION_EVALS \
  --margin-bin build/margin \
  --holdout-key-file /secure/path/margin-collaboration.key \
  --tool-mode trusted \
  --team mixed=openai/MODEL_A,anthropic/MODEL_B \
  --repetitions 5 \
  --experiment candidate-v2
```

Roles are assigned to team models in order and wrap for larger teams. Sequential roles receive no transcript from earlier agents; they see only the shared Markdown collaboration state. Concurrent phases launch separate Prime Agent processes against the same ephemeral directory. `--tool-mode shell` is reserved for opt-in adversarial research and additionally requires `--confirm-shell-research ALLOW_UNRESTRICTED_SHELL_RESEARCH`; it is not an isolated default or a pilot configuration.

Before each live task, the harness injects the smallest applicable static `capabilities --json --for WORKFLOW` projection and only the command-local help missing from it. The reference is byte-bounded and contains no fixture state; the agent can request the full catalog only when focused discovery is insufficient.

The completed Luna + Terra pilot and its harness findings are documented in [Docs/COLLABORATION_EVALS.md](../../Docs/COLLABORATION_EVALS.md). `--token-budget` limits generated/output tokens per Prime subprocess; it is not a cap on input or cache-read tokens. Future reports preserve the legacy token fields while labeling that meaning and separately reporting actual input, generated output, cache read/write, and cost. A prior pilot does not authorize another model run.

## Paired comparison

Use the same holdout key, suite version, team names, scenarios, and repetition indices for baseline and candidate:

```sh
Evals/collaboration/compare.py \
  BASELINE/eval-set.json CANDIDATE/eval-set.json \
  --output comparison.json
```

The comparison pairs exact configuration/scenario/repetition cells and reports deterministic 95% bootstrap confidence intervals for score, command count, duration, tokens, and cost. New safety or policy failures, missing cells, case-fingerprint mismatches, and large paired score losses are hard regressions.

## Privacy

The harness never retains raw prompts, Markdown, comment bodies, host filesystem paths, actor identities, environment values, credentials, or model transcripts. Agent subprocesses receive an allowlisted environment that omits host API keys, tokens, and unrelated variables. Prime retains its configured home only for authentication, but the default model has no shell/filesystem tool with which to inspect it. The trusted extension invokes the existing proxy without a shell, in a fixed workspace, and bounds argv, staged JSON input, runtime, and output. Ephemeral workspaces and raw process output are destroyed after scoring. Retained evidence is limited to synthetic workspace-relative paths, boolean checks, counts, timings, usage, stable error codes, and SHA-256 hashes. Agent attempts to inspect disallowed state are recorded only as hashed policy violations.

See [Docs/COLLABORATION_EVALS.md](../../Docs/COLLABORATION_EVALS.md) for scenario semantics, contract-oracle mapping, capability gates, and the POSIX visibility boundary.
