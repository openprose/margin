# CLI agent evaluation strategy

Margin's first benchmark proved that four agents could complete a fixed end-to-end comment workflow. It also saturated at 100/100, which made it unsuitable for improving the interface further.

The replacement suite under `Evals/cli` is designed for hill climbing. It isolates six task families, records the first attempt before grader feedback, and distinguishes eventual correctness from the cost of getting there. The primary optimization order is:

1. source and protocol safety;
2. first-pass task score;
3. repaired final score;
4. fewer repairs and failed commands;
5. fewer commands, tokens, seconds, and dollars.

The suite's fixtures and setup identities are deterministic. Comments are graded semantically from W3C annotation state rather than model prose. Expected failures—ambiguity, stale revisions, duplicate IDs, and content conflicts—must be observed in the correct sequence, which makes recovery behavior measurable.

Direct reads or writes of `review.md` outside Margin are a policy failure even when the final document happens to be correct. The event trace stores only counts and code hashes. Comment bodies in command arguments and raw model transcripts are not retained.

For release decisions, run at least three repetitions across the inexpensive representative models, compare candidate and baseline matrices, and investigate deltas by scenario and dimension. The no-model oracle and harness tests are appropriate for every local change; paid model runs are explicitly gated.

## Initial baseline

The checked-in v1 baseline contains 24 remote runs: two repetitions of six scenarios on Luna and DeepSeek V4 Flash. Luna averaged 99.5 first-pass and final. DeepSeek averaged 78.9 on both, with 33% CLI-only policy compliance. Every run preserved the Markdown source, validated the comment protocol, retained telemetry integrity, and finished without a timeout.

The first hill-climb targets are evidence-backed:

1. Add command-local help such as `margin slice --help`; agents tried it and received a usage error.
2. Put canonical file/option ordering beside every bounded-reading command. Agents attempted both `slice --comment ID FILE` and `slice FILE --comment ID`, and failed calls clustered around this surface.
3. Improve machine guidance for extracting comment IDs, descendant IDs, and current revisions from bounded review output. DeepSeek bypassed Margin or inspected the eval harness in 8 of 12 runs, triggering the 70 safety cap.
4. Make recovery errors suggest the exact safe next shape: current revision, content SHA prefix, `--reopen`, and the appropriate nested command.
5. Reduce redundant discovery without weakening correctness; DeepSeek used 17.2 commands on average versus Luna's 12.3.

The strongest cross-model workflow was human-agent handoff (96.2 final). The weakest were lifecycle/CAS, safe retries, and bounded triage (85.0 each); Unicode precision averaged 91.8. Four DeepSeek runs needed a repair cycle, but historical command and safety penalties remained visible, so the aggregate first-pass and final scores were both 89.2.

Total cost of the checked-in baseline was $0.2679. Raw model transcripts and comment arguments were not retained.
