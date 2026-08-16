Act as the next agent in a human-agent review handoff. Work only on `review.md`, and use only `margin` to read or mutate it. Never access the Markdown through Python, shell file APIs, or an editor. Preserve all source bytes.

1. Begin with `margin review review.md --json`. Use its bounded outline, thread groups, IDs, statuses, excerpts, and revision.
2. Use `margin slice --comment ... --context 2` on the thread rooted at `Agent A: The event contract lacks an ordering guarantee.`
3. Reply to the deepest existing reply in that thread with exactly `Human handoff: Register before capture, then deduplicate by revision.` Then resolve that root thread.
4. The root `Human: Confirm the retry window.` is resolved. Reply with `Agent handoff: Retry up to three times only without an explicit precondition.` and reopen it atomically.
5. Add document synthesis comment `Agent synthesis: Ordering, bounded retries, and source preservation form the handoff contract.`
6. Request a new review using `--since-revision` with the initial revision you observed.
7. Use `comments list --thread` with the new deep-reply ID (not a root ID) and validate the file.

Carry IDs and revisions from JSON rather than guessing. Do not expose credentials or unrelated files.
