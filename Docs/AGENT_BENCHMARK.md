# Margin agent benchmark

Run date: 2026-08-16

## Result

All four agents scored **100/100**, exited cleanly through the benchmark completion gate, and preserved the fixed Markdown source byte-for-byte. The four reported runs cost **$0.2168 total** as reported by Prime Agent.

| Model | Score | Time | Input tokens | Output tokens | Cost | Source preserved |
|---|---:|---:|---:|---:|---:|:---:|
| `openai/gpt-5.6-terra` | 100/100 | 27.500 s | 12,575 | 1,207 | $0.0584 | yes |
| `openai/gpt-5.6-luna` | 100/100 | 31.530 s | 14,783 | 2,030 | $0.0068 | yes |
| `openai/gpt-5.6-sol` | 100/100 | 32.643 s | 14,528 | 1,430 | $0.1432 | yes |
| `openrouter/deepseek/deepseek-v4-flash` | 100/100 | 68.900 s | 17,787 | 4,307 | $0.0083 | yes |

Terra was fastest in this run. Luna had the lowest measured cost. Results are single-run observations, not estimates of general model quality or provider latency.

An earlier four-model calibration also reached 100/100, but exposed a harness issue: autonomous mode had no completion gate, so Prime Agent continued after success and eventually returned a limit status. Those calibration runs cost $0.2556 and are excluded from the table. The combined remote-model spend during benchmark development was therefore **$0.4724**.

## Method

Each model received an isolated copy of the same Markdown fixture as `review.md`, no Margin command grammar, and the instruction to begin with `margin --help`. It had to use only Margin to:

1. discover and use `inspect`, `outline`, and `slice`;
2. create quote-, Unicode-scalar-range-, and document-anchored comments;
3. create a reply and a nested reply;
4. observe an ambiguity failure, then select the second quote occurrence;
5. resolve one root thread while leaving the others open; and
6. finish with machine-readable `list` and `validate` checks.

The scorer independently queried the resulting file with the built Margin CLI. Its 100 points cover command discovery/evidence, every requested annotation and relationship, ambiguity handling, resolution, final validation, and exact logical-source preservation. The same scorer was used as Prime Agent's completion gate, so a process returned successfully only after all 100 points passed.

“Source preserved” means the Markdown body bytes exactly equal the original fixture. Margin's terminal embedded comment envelope is intentionally additional file content.

## Run controls

- Models ran sequentially with medium thinking.
- Each run used a 16,000-token autonomous budget, a six-turn continuation threshold, at most two host-injected continuations, and a 300-second Prime Agent wall-clock limit.
- The outer runner allowed 30 seconds for graceful process cleanup beyond that wall-clock limit.
- Every model finished without timing out and returned process exit code 0.
- The fixture, task, model matrix, runner, proxy, scorer, and report generator live under `Benchmarks/agent_benchmark/` and `Fixtures/agent-benchmark/`.

## Privacy and retained evidence

The runner used the user's existing Prime Agent authentication without reading, copying, or passing credentials. It discarded model stdout and stderr after extracting aggregate usage. It retained only redacted Margin command shapes, exit statuses, timing, hashes, scores, and aggregate usage/cost metrics. No raw model transcript, session, environment dump, API key, or command output was stored.

The tracked machine-readable counterpart is `Benchmarks/agent_benchmark/RESULTS.json`.

## 0.2 blind workflow extension

A separate fresh agent tested the final 0.2 CLI without source access or a supplied grammar. It received only `margin --help` and an isolated Markdown copy, then successfully:

1. obtained a bounded review snapshot;
2. added a quote-anchored passage comment and reply;
3. edited the reply;
4. started `comments watch`, observed a resolve mutation, and stopped cleanly;
5. validated the final document; and
6. compared the original logical SHA-256 with `margin read` output.

Review, slicing, and mutations each completed in 0.00–0.01 seconds in that run. The watch change timestamp followed the resolve by roughly 71 ms, reported `commentsChanged: true` / `contentChanged: false`, and exited 0 on interruption. The logical source digest remained exactly `ed94b8a3f06a450ed5318307e266212495ee83c8f103ceef55b1bb3f42b112bc`.

The blind run identified unclear ID/digest/pretty-print help text. The final CLI now explains that `--id UUID` becomes `urn:uuid:UUID`, later commands accept either form, returned root/annotation IDs serve different follow-up operations, `contentSha256` is the CAS form, and all JSON read commands accept `--pretty`. No external model API or paid run was used for this extension, and its temporary fixture was removed.
