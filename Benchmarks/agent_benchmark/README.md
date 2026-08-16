# Margin real-agent benchmark

This suite measures whether a fresh coding agent can discover Margin from `margin --help` and complete a realistic Markdown review entirely through the CLI. It does not give the model Margin's command grammar.

The fixed source artifact is `Fixtures/agent-benchmark/atlas-launch-review.md`. Every model receives an isolated copy named `review.md`. The task requires inspect, outline, and slice reads; quote, range, and document comments; two levels of replies; deliberate ambiguity handling; resolution; and final list/validation checks.

The latest four-model redacted comparison is in [`RESULTS.md`](RESULTS.md). It contains scores and aggregate metrics, never transcripts.

## Local CLI contract

Before benchmarking an agent, exercise the built command directly:

```sh
Benchmarks/cli_contracts.sh build/margin
python3 Benchmarks/agent_benchmark/self_test.py --margin-bin build/margin
```

The first command covers discovery, JSON envelopes and errors, ambiguity, idempotency, stale-write rejection, nested thread filtering, resolve/reopen, source preservation, and new-file opening. The oracle self-test completes and scores the entire benchmark task without invoking a model.

## Safety and privacy

- The runner uses Prime Agent's already-configured authentication. It never opens, copies, prints, or passes an API key.
- Paid runs require both `--execute` and the literal confirmation `--confirm-paid RUN_PAID_MODELS`.
- Prime Agent stdout and stderr stay in memory and are discarded. `run.json` stores only byte counts, SHA-256 digests, timing, token usage, and cost metrics.
- The Margin proxy logs redacted argument vectors, durations, and exit codes. It never records command output or environment variables.
- Each run has a token cap, turn cap, Prime Agent wall-clock cap, and an outer process timeout.
- The 100-point scorer is also Prime Agent's completion gate, so a run stops as soon as the requested document state and command evidence are both verified.

## Dry run

The dry run checks the fixed fixture, creates and verifies an isolated temporary copy, locates Prime Agent, confirms the four configured model IDs, and probes `margin --help`. It never invokes a model:

```sh
python3 Benchmarks/agent_benchmark/run.py --dry-run
```

Before the CLI is complete, `margin.ready` is expected to be `false`; this does not launch or bill anything.

## Paid execution

After the complete CLI is built, run one model:

```sh
python3 Benchmarks/agent_benchmark/run.py \
  --execute \
  --model openai/gpt-5.6-luna \
  --margin-bin build/margin \
  --confirm-paid RUN_PAID_MODELS
```

Run the full fixed matrix sequentially:

```sh
python3 Benchmarks/agent_benchmark/run.py \
  --execute --all \
  --margin-bin build/margin \
  --confirm-paid RUN_PAID_MODELS
```

Configured models:

- `openai/gpt-5.6-luna`
- `openai/gpt-5.6-terra`
- `openai/gpt-5.6-sol`
- `openrouter/deepseek/deepseek-v4-flash`

Defaults are 24,000 tokens, eight turns, medium thinking, and 420 seconds per run. Flags can lower any cap.

## Scoring

The scorer calls Margin's JSON `comments list` and `comments validate` commands directly, then compares the logical Markdown body byte-for-byte with the fixed fixture. Command-log evidence verifies that the agent actually used help, inspect, outline, slice, range mode, occurrence disambiguation, list, and validate.

```sh
python3 Benchmarks/agent_benchmark/score.py \
  --run-dir Benchmarks/agent_benchmark/runs/RUN_ID \
  --margin-bin build/margin
```

Generate a sanitized leaderboard:

```sh
python3 Benchmarks/agent_benchmark/report.py \
  --json-out Benchmarks/agent_benchmark/runs/summary.json \
  --markdown-out Benchmarks/agent_benchmark/runs/REPORT.md
```

Run directories are ignored by Git and contain only the isolated artifact, redacted Margin command log, score, report, and sanitized run metrics.
