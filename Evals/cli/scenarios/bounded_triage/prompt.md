Triage `review.md` as an experienced architecture agent. Use only `margin`; never read or mutate the file through Python, shell file APIs, `cat`, or an editor. Preserve the Markdown source exactly.

This is a larger note. Start with `margin inspect ... --json`, then `margin review ... --json`. Do not use `margin read`. Use bounded `slice --comment ... --context 2` calls for at least two relevant threads.

Complete the review:

1. Reply to deepest existing comment under `Agent: The failover owner is unclear.` with `Triage: route ledger ownership must be confirmed before evacuation.`
2. Resolve root `Human: Verify the cache invalidation sequence.`
3. Leave `Agent: The audit sink needs a retention bound.` open.
4. Add a new quote comment on the **second** occurrence of exact text `region failover` (the one in `Decision Ledger`) with `Triage: make the human decision point explicit in the launch checklist.`
5. Request a final review using `--since-revision` with the initial revision you observed, then validate.

Carry IDs and revisions from output. Keep the command sequence bounded and do not inspect unrelated files or credentials.
