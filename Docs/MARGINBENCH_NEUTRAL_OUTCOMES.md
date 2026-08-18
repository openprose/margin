# MarginBench representation-neutral outcomes

Status: design draft; no control may use it for a paid run until the reference
parser, projections, adversarial tests, and served preflight pass.

This contract lets MarginBench compare agents using Margin with agents using
only ordinary Markdown files. It grades what collaborators accomplished, not
where or how a tool stored it.

## The common fact model

Every candidate is projected into the same small set of facts before scoring:

- stable fact ID;
- kind: comment, question, issue, decision, task, approval, suggestion, handoff,
  or reply;
- related document and optional exact source passage;
- exact Markdown body;
- declared author actor ID plus the trusted actor that first introduced the
  fact;
- open, resolved, accepted, or rejected state;
- optional parent/root fact ID;
- optional intended next actor, assignee, priority, or audience;
- for suggestions, expected text, replacement text, and decision actor;
- for an all-or-none update, one transaction-group ID.

The scorer also receives the exact expected logical source for each document
and a normalized event record for conflicts, retries, policy blocks, and
writes. That trusted record binds each successful write to the active role and
records only affected fact IDs and before/after digests, not private bodies. It
never reads a model transcript and never asks another model to judge semantic
similarity.

Margin annotations are projected into these facts by a read-only adapter. The
plain-Markdown control is projected by parsing one disclosed file named
`COLLABORATION.md`. Projection errors fail that fact; they never trigger a
best-effort guess.

## Plain Markdown interchange

Each benchmark fixture supplies an initially empty `COLLABORATION.md` with this
human-readable record shape:

```markdown
# Collaboration

## FACT_ID

- Kind: issue
- File: review.md
- Author: urn:example:agent
- State: open
- Parent: none
- Root: FACT_ID
- Next actor: none
- Assignee: none
- Priority: none
- Audience: none
- Expected text: none
- Replacement text: none
- Decision by: none
- Transaction: none

### Body

Exact Markdown body.
```

Records are ordered by ID for deterministic rewrites. `none` is literal.
Single-value fields occupy exactly one line; generated identifiers and source
passages never contain line breaks. The body is everything after `### Body`
until the next level-two fact heading. Duplicate headings, unknown required
fields, invalid actor/parent references, and cycles are errors. Unknown
optional fields are preserved but receive no credit.

`Author` is not trusted merely because an agent typed it. The gateway records
the bound actor under which each fact ID first appeared; those values must
match. Likewise, `Decision by` must match the bound actor on the write that
first changed a suggestion to accepted or rejected. Harness-created human facts
carry equivalent trusted provenance. Later whole-file rewrites may preserve an
earlier fact, but cannot acquire its authorship. A forged attribution remains
visible for diagnosis and fails the relevant check instead of being silently
rewritten by the gateway.

This is deliberately less capable than Margin's embedded protocol. It is an
ordinary visible Markdown ledger, contains no hidden metadata, and uses no
sidecar database. The file gateway offers only bounded list/read and one-file
compare-and-swap replacement. Agents may choose another Markdown layout, but
only the supplied layout has a deterministic public parser and can earn
structured-fact credit.

## Comparable checks

The common score contains only checks available to both representations:

- **Outcome:** every expected fact exists once with the exact body, kind,
  relationship, state, trusted author, and task-specific properties; no
  unexpected fact was added.
- **Integrity:** expected source bytes, unrelated text, fact IDs, and graph
  relationships remain intact; required grouped work is all present or all
  absent.
- **Continuity:** a later isolated role discovers and acts on the earlier
  role's durable fact without receiving its transcript.
- **Recovery:** the normalized event log shows the required stale/conflict
  condition and a correct final recovery, regardless of product-specific error
  wording.
- **Efficiency:** bounded tool calls, bytes read and written, tokens, elapsed
  time, and observed cost are reported separately and then normalized against
  profile-specific reference ceilings.
- **Safety:** no path escape, hidden-fixture access, source corruption, partial
  grouped result, or policy bypass occurred.

Margin-specific command use, JSON-LD validity, anchor-repair internals, stage
lineage, and protocol error codes stay in the Margin track as descriptive
diagnostics. They are not zeros in the neutral score.

## Scenario projections

| Workflow | Representation-neutral success |
| --- | --- |
| Human to agent | The human question and exact agent reply form one resolved thread with correct authors; source is unchanged. |
| Agent to agent | The first agent leaves an open handoff for the second; the isolated second agent finds it, adds the exact acknowledgement, and resolves it. |
| Concurrent review | Both independently authored issues survive exactly once despite concurrent stale views; source is unchanged. |
| Suggestion decision | Both exact proposals and rationales remain recorded; only the accepted replacement changes source; the second is explicitly rejected by the reviewer. |
| Staged multi-file | The two expected issues and human drift all survive; the paired issues share one transaction group and are never externally observed in a partial state. |
| Directory handoff | The architecture answer resolves the human question and a separate directory-visible handoff reaches the isolated reviewer, who acknowledges and resolves it. |

For grouped visibility, the gateway records the fact-ID set after every
successful write. The all-or-none check therefore covers intermediate exposed
states, not merely a repaired final snapshot. A single compare-and-swap rewrite
of `COLLABORATION.md` can commit multiple facts atomically; sequential partial
writes cannot earn the check.

## Gates before implementation is runnable

1. Freeze a versioned JSON schema for the common facts, trusted write
   provenance, and neutral score.
2. Build both projections and prove that equivalent Margin and Markdown
   fixtures produce byte-identical canonical facts.
3. Add reference solutions for all six workflows that score 100 without using
   Margin.
4. Add adversarial cases for duplicate IDs, forged authors/decision-makers,
   attribution laundering through a later whole-file rewrite, parent cycles,
   malformed bodies, stale compare-and-swap, symlink/path escape, oversized
   files, and partial grouped visibility.
5. Run both profiles through the same in-process and served fake-model matrix,
   with identical hidden cases, logical role budgets, sampling, and ordering.
6. Publish separate neutral and Margin-protocol tables; never merge them into a
   single historical leaderboard score.

Until those gates pass, `role-separated-plain-markdown-v1` remains
`specified-not-runnable` and every paid runner must reject it before reading
credentials or creating output.
