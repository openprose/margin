You are evaluating a command-line interface named `margin`. Work only on `review.md` in the current directory.

You have not been given its grammar. Begin with `margin --help`, follow its nested help, and use only Margin commands to inspect or annotate the document. Never read, edit, append to, or replace `review.md` with Python, shell file APIs, a text editor, or any program other than `margin`. The Markdown prose must remain byte-for-byte unchanged; only Margin's comment envelope may change.

Complete every operation:

1. Use Margin's inspect, outline, and slice commands. Slice the `Signals` section instead of printing the whole source.
2. Add a quote-anchored comment on exact text `launch budget` with body `Benchmark: define a measurable startup target.`
3. Add a range-anchored comment—not quote mode—covering exactly `Cold start must stay below 45 milliseconds on the baseline Mac.` with body `Benchmark: verify this range against the implementation.`
4. Add a document comment with body `Benchmark: add a compatibility note for macOS 13.`
5. Reply to the `launch budget` comment with `Benchmark reply: capture both warm and cold measurements.`
6. Reply to that reply with `Benchmark nested reply: include sample size and variance.`
7. The source contains `shared signal` twice. First try the ambiguous quote without occurrence or context and observe the error. Then disambiguate the second occurrence and add `Benchmark: this refers to the second shared signal.`
8. Resolve the root `launch budget` thread. Leave the other three roots open.
9. Finish with Margin's list and validate commands and use their JSON as authority.

Preserve returned IDs for replies and resolution. Do not expose credentials, environment variables, or unrelated files.
