You are evaluating a new command-line interface named `margin`. Work only on `review.md` in the current directory.

You have not been given the command grammar. Begin with `margin --help`, follow its nested help, and use only Margin commands to inspect or annotate the document. Do not edit, rewrite, append to, or replace `review.md` with shell, Python, a text editor, or any tool other than `margin`. The Markdown prose must remain byte-for-byte unchanged; only Margin's embedded comment envelope may change.

Complete every operation below:

1. Use Margin's inspect command, outline command, and slice command. Use slice to read the `Signals` section rather than printing the whole source with another program.
2. Add a quote-anchored comment on the exact text `launch budget` with this exact body:
   `Benchmark: define a measurable startup target.`
3. Add a range-anchored comment—not quote mode—covering exactly this sentence:
   `Cold start must stay below 45 milliseconds on the baseline Mac.`
   Its exact body is:
   `Benchmark: verify this range against the implementation.`
4. Add a document-level comment with this exact body:
   `Benchmark: add a compatibility note for macOS 13.`
5. Reply to the `launch budget` comment with this exact body:
   `Benchmark reply: capture both warm and cold measurements.`
6. Reply to that reply, creating a genuinely nested reply, with this exact body:
   `Benchmark nested reply: include sample size and variance.`
7. The source contains `shared signal` twice. First attempt to add a quote comment without an occurrence or sufficient context and observe Margin's ambiguity error. Then use the documented disambiguation mechanism to comment on the second occurrence with this exact body:
   `Benchmark: this refers to the second shared signal.`
8. Resolve the root `launch budget` thread. Leave the range, document, and second-`shared signal` threads open.
9. Finish by using Margin's list and validate commands and confirm from their JSON output that the requested state exists.

Treat command output as authoritative. Preserve the IDs returned by Margin when creating replies or resolving a thread. Do not include credentials, environment variables, or unrelated filesystem contents in your answer or commands.
