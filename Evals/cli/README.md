# Margin CLI agent evals

This suite measures whether an agent can discover and safely use Margin's CLI—not whether it can imitate a transcript. Every case begins from an isolated synthetic Markdown fixture and is graded from the resulting annotation graph, the CLI's machine-readable receipts, and privacy-preserving command telemetry.

The checked-in [v1 baseline](baselines/v1.md) contains two repetitions of all six scenarios on Luna and DeepSeek V4 Flash. Its portable JSON companion is suitable as the left-hand input to `compare.py`.

## What it measures

The six fixed scenarios separate failure modes that the original single benchmark had collapsed into one saturated score:

| Scenario | Primary behavior |
|---|---|
| `discovery_review` | Help discovery, reading primitives, all anchor modes, nested replies, ambiguity, resolution |
| `anchor_precision` | Grapheme coordinates, Unicode, context disambiguation, literal Markdown punctuation |
| `lifecycle_cas` | Edit/delete, stale revision recovery, resolved-thread reopen, descendant lookup |
| `human_agent_handoff` | Bounded review, deep replies, comment-oriented slices, incremental handoff |
| `safe_retries` | Idempotency keys, ID conflicts, revision/content compare-and-swap |
| `bounded_triage` | Selective reading and command efficiency on a larger architecture note |

Every scenario has 100 deterministic points grouped into discovery, review, anchoring, threading, lifecycle, concurrency, recovery, verification, efficiency, and safety dimensions. Source mutation, invalid protocol data, and direct non-Margin document access impose non-compensatory score caps.

## Fast local checks

Run the complete no-model oracle and harness tests:

```sh
make eval
```

Or inspect the full preflight, including configured-model availability, without invoking a model:

```sh
Evals/cli/run.py --margin-bin build/margin
```

Both paths report `paidModelsInvoked: false`.

Remote cases run through a headless proxy: accidental file/open invocations receive a usage error instead of launching the Mac app during an eval.

## Remote agent runs

Remote execution is deliberately double-gated. Select models explicitly and provide the literal confirmation:

```sh
Evals/cli/run.py \
  --execute \
  --confirm-paid RUN_PAID_EVALS \
  --model openai/gpt-5.6-luna \
  --repetitions 3 \
  --experiment cli-help-v2 \
  --margin-bin build/margin
```

Use `--all-models` for the configured matrix and `--scenario NAME` to focus on a failure cluster. Prime Agent uses the existing user login; the runner never accepts, reads, or records API keys.

To add repetitions later without rerunning earlier cells, use `--repetition-start 2` (or the next unused index), then merge the resulting sets.

Each run retains:

- first completion-gate score and failed checks;
- final repaired score and deterministic dimension scores;
- command verbs/options, exits, stable error codes, durations, and output hashes;
- direct-document-access counts and hashes;
- token usage, time, model, cost, and budgets.

It does not retain raw model output, raw stderr/stdout, comment-message arguments, quoted source text, credentials, or environment dumps.

## Hill-climbing workflow

1. Run a baseline with at least three repetitions per model/scenario.
2. Change one CLI surface: help, command grammar, JSON shape, error wording, or recovery affordance.
3. Run the identical fixed suite against the candidate binary with the same models, thinking level, budgets, and repetitions.
4. Compare both sets:

```sh
Evals/cli/compare.py BASELINE/eval-set.json CANDIDATE/eval-set.json
```

5. Prefer changes that raise first-pass score, then reduce repairs, commands, time, tokens, and cost without lowering final correctness or any safety invariant.

First-pass score is the cleanest usability metric: it is captured before the completion gate explains omissions. Final score measures recoverability after bounded diagnostics. A candidate that needs more gate repairs is less legible to agents even if it eventually reaches 100.

The completion gate only reports repairable task-state omissions. It never asks an agent to repair elapsed commands, prior errors, source-policy violations, or other historical metrics. Those remain final observational penalties. Gate records include command counts, and a shrinking command log triggers a telemetry-integrity cap.

`compare.py` pairs model/scenario/repetition cells, fails on missing cells, final-score loss, new safety violations, or command growth without a score gain. Stochastic model runs still require judgment; use multiple repetitions and inspect scenario/dimension clusters rather than overfitting one sample.

Separate model runs can be combined into one matrix before comparison:

```sh
Evals/cli/merge.py luna/eval-set.json deepseek/eval-set.json \
  --experiment baseline-v1 --output baseline-v1.json
```

If only deterministic grading logic changes, retained workspaces can be rescored without another model call:

```sh
Evals/cli/rescore.py OLD/eval-set.json --output OLD/rescored.json --margin-bin build/margin
```

Scenario fingerprints include the manifest, prompt, fixture, oracle, and suite weight, so incompatible task revisions cannot be merged silently.

Create a portable baseline with absolute paths and verbose event counts removed:

```sh
Evals/cli/snapshot.py merged.json --output baselines/v1.json
```

## Adding a scenario

Add a directory under `scenarios/` with:

- `fixture.md`: synthetic, non-sensitive, immutable Markdown;
- `prompt.md`: task contract and CLI-only safety rule;
- `oracle.json`: a perfect no-model command sequence;
- `scenario.json`: setup operations, 100 points of checks, dimensions, and safety caps.

Then add its ID and weight to `suite.json`. The loader rejects missing assets, duplicate check IDs, unknown selections, and point totals other than 100. The oracle must score 100 before the case is eligible for model execution.

Keep prompts outcome-oriented. Do not encode a full command transcript; a useful eval must leave room for CLI discovery and recovery behavior to differ.
