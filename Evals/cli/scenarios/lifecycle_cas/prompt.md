Work only on `review.md`, exclusively through the `margin` CLI. Do not read or write the file with Python, shell file APIs, or an editor. Preserve the Markdown source exactly.

This file already contains two comment threads. Start with `margin review ... --json`; use its IDs, statuses, and revision as authority.

1. Edit the reply whose body is `Architect: SRE owns the first decision point.` to exactly `Architect revision: SRE owns the handoff at minute five.` Use the observed revision as `--if-revision`.
2. Delete the leaf `Agent draft: old wording.` First deliberately use the now-stale revision you originally observed and confirm `REVISION_CONFLICT`; then use current state and retry conditionally.
3. Reply to resolved root `Human: this legacy note is complete.` first without `--reopen` and confirm `THREAD_RESOLVED`; then atomically reopen and reply with `Agent: reopening because the retired path still affects migration.`
4. Resolve the root `Human: clarify the rollback owner.` using the current revision.
5. Use `comments list --thread` with a descendant ID from that thread, then validate the document.

Do not guess IDs or revisions; preserve values returned by Margin. Do not expose credentials or unrelated files.
