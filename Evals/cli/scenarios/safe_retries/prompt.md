Work only on `review.md` and use only `margin`; do not read or write the file using Python, shell file APIs, or an editor. Preserve the Markdown bytes exactly.

Start with `margin inspect review.md --json` and retain both the comment revision and content SHA.

1. Add a quote comment on `release token` with exact body `Retry eval: this approval has an idempotency key.` Use ID `50000000-0000-4000-8000-000000000001`, `--if-revision 0`, and the observed content SHA.
2. Repeat that exact semantic add with the same ID and original preconditions. Confirm it succeeds idempotently without advancing the revision.
3. Attempt the same ID with different body `Retry eval: conflicting reuse must fail.` and observe `ID_CONFLICT`.
4. Add document comment `Retry eval: conditional recovery succeeded.` with ID `50000000-0000-4000-8000-000000000002`. First deliberately use stale revision 0 with the correct content SHA and observe `REVISION_CONFLICT`. Then use current revision 1 but an all-zero SHA and observe `CONTENT_CONFLICT`. Finally retry with current revision 1 and the correct observed content SHA.
5. List and validate the final state. There must be exactly two open root comments at revision 2.

Treat JSON as authoritative. Do not expose credentials or unrelated files.
