# MarginBench representation-neutral outcomes

Status: runnable. The interchange schema, strict parser/encoder, hidden-oracle
projection, confined file gateway, durable trusted event record, deterministic
neutral scorer, prompt audit, fresh-process isolation proof, exact Prime
production rehearsal, and non-ranking efficiency report are implemented and
passing.

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

Each benchmark fixture supplies a scaffolded `COLLABORATION.md` containing the
heading and format marker but no fact records. Records use this human-readable
shape:

```markdown
# Collaboration

Format: marginbench-neutral-v2

## FACT_ID

Kind: issue
File: review.md
Quote: none
Author: urn:example:agent
State: open
Parent: none
Root: FACT_ID
Next actor: none
Assignee: none
Priority: none
Audience: none
Expected text: none
Replacement text: none
Decision by: none
Transaction: none
Body JSON: "Exact Markdown body."
```

`Audience` is either `none` or a canonical compact JSON array of actor IDs.
Unknown visible extension fields are permitted only with an `X-` prefix and are
preserved in sorted order; they receive no score.

Records are ordered by ID for deterministic rewrites. `none` is literal.
The exact format marker is required; unknown versions fail closed instead of
being interpreted as v1. Line endings are LF and the file is UTF-8 without a
byte-order mark.
Single-value fields occupy exactly one line; generated identifiers and source
passages never contain line breaks. `Body JSON` is one canonical JSON string,
so arbitrary Unicode remains readable while quotes, line breaks, headings, and
delimiter-looking text are escaped without any manual byte counting. Invalid
UTF-8, noncanonical JSON strings, line endings,
duplicate headings, unknown required fields, invalid actor/parent references,
and cycles are errors. Unknown optional fields are preserved but receive no
credit.

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

A model-free feasibility sweep generated 100 public repetitions of each of the
original six workflows (600 cases) and checked 9,600 identifier, path, actor,
kind, status, relationship, and expected-text fields. Every scalar satisfied
the v1 single-line rule. The executable projection now additionally covers all
nine current workflows across generated repetitions, round-trips exact Unicode
and delimiter-shaped bodies through the byte parser, and validates the
canonical JSON fact schema. This proves representability, not gateway or
scoring fairness.

## Deterministic projection order

The implemented parser operates on bytes, not a forgiving rendered-Markdown
tree:

1. Require canonical UTF-8/LF bytes, the exact heading, and the v2 marker.
2. Read each level-two ID and every required single-line field exactly once.
3. Parse `Body JSON` as one canonical JSON string. Literal newlines and record
   delimiters inside a body are escaped, so an agent never computes byte
   lengths and the parser never searches through body text.
4. Require the canonical separator or end of file.
5. Validate IDs, paths, enums, actor provenance, parent/root relationships,
   cycles, and task-specific fields before emitting any facts.
6. Sort canonical facts by ID and encode them with the versioned neutral schema.
7. Join the trusted write events by fact ID only after both inputs validate.

Parsing is all-or-nothing. Diagnostics may report a bounded byte offset and
stable error code, but may not include private body text or silently recover a
partial ledger.

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
- **Efficiency:** model calls, input/output tokens, tool round-trips, bytes read
  and written, elapsed time, and observed cost are reported separately. Tool
  calls are descriptive because one Margin operation and one whole-file rewrite
  do not carry equal work. No profile-specific ceiling may be used to claim one
  representation is more efficient. The v1 report schema forbids a scalar
  efficiency score and a winner; adding either requires a new schema and a
  separately justified study design.
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

## Completed release gates

The common-fact schema and neutral receipts bind trusted provenance; the Margin
and ledger projections share the same hidden outcomes; oracle-free reference
agents complete all nine workflows; adversarial parser, identity, path,
conflict, Unicode, delimiter, and grouped-visibility cases pass; both profiles
run through the same isolated Prime path; gateway resource use is measured;
and representation evidence stays separate from Margin's protocol score.

## Implemented gateway boundary

The local prerequisite gateway now exposes bounded one-directory listing,
bounded line reads with a whole-file digest, and one-file compare-and-swap
replacement. It accepts only canonical UTF-8/LF Markdown, uses a shared
workspace lock and same-directory atomic replacement, preserves the file mode,
and records the trusted writer separately from the author claimed in a fact.
It rejects path traversal, hidden paths, symlink and hard-link targets,
case-aliased ledger names, stale digests, oversized files and directories,
malformed ledgers, noncanonical JSON bodies, and noncanonical rewrites. Concurrent
writes from the same cursor deterministically produce one success and one stale
failure.

The agent-facing plain control exposes progressively disclosed
guide/list/read/write actions and no
shell or Margin binary. A private, append-only, locked event record works across
independent processes and feeds a schema-backed state assessment.
It separately checks exact facts, unexpected facts, source bytes, final and
historical all-or-none state, first-writer attribution, suggestion decision
identity, read-before-action continuity, and required stale-write recovery. It
deliberately publishes no overall score. Its own receipt keeps efficiency
`notEvaluated` because a scripted no-model run cannot measure agent efficiency;
the separate efficiency report preserves useful resource observations without
turning them into a ranking.

All nine workflows now pass the served Prime path end to end while
pointing at a deliberately nonexistent Margin binary. It records content-free
tool call counts, request/response byte counts, local tool latency, and
available model-token counts in a schema-validated receipt. These remain
observations, not a scalar efficiency score. The shared report is now
schema-backed, digest-bound to its sources, null-preserving, and checked against
tampered totals. The independent audit passes all 85 prompt projections in its
five-seed matrix. The Prime subprocess isolation proof passes all nine workflows
with 17 fresh role processes, 105 local model-shaped requests, 88 verified
same-role continuations, and zero cross-role canary leaks. The final production
rehearsal drives Prime's actual evaluation command and validates both official
non-scalar result formats without a paid model.

The current free feasibility gate is:

```sh
PYTHONPATH=Evals/marginbench \
  python3 -m marginbench.cli neutral-feasibility
```

It covers all nine workflows and emits a schema-validated receipt with
`paidModelsInvoked: false`.

The separate served boundary is:

```sh
PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/python -m marginbench.cli \
  neutral-served-preflight
```

It uses an oracle-free scripted role policy, invokes no model, exposes only the
`workspace` tool, and validates a versioned content-free receipt.

The exact production-path rehearsal is:

```sh
PYTHONPATH=Evals/marginbench \
  ~/.local/share/uv/tools/prime/bin/python -m marginbench.cli \
  neutral-production-preflight
```

It launches the same Prime taskset, environment, tool server, fresh role
processes, trace aggregation, and publication builders used by a paid run, but
routes inference to a local scripted endpoint. Raw prompts and transcripts are
destroyed with the temporary workspace.

The frozen descriptive resource projection is:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli efficiency-report \
  build/benchmarks/neutral-served-preflight.json \
  Evals/marginbench/results/crossover/v17/cells/*.run.json \
  > build/benchmarks/efficiency-report.json
```

It reports wall time, calls, failures, bytes, tool time, tokens, and cost as a
vector. A scripted neutral cell and a real-model Margin cell are explicitly
marked `mixed-execution-kind`; neither can be declared the winner.

Those gates now pass, so `role-separated-plain-markdown-v1` is implemented. A
paid run needs no Margin binary and is forced onto the representation track.
Its schema forbids a scalar score or winner; cross-representation comparison is
limited to explicit outcomes, integrity checks, and resource measurements.

## First real-model representation probe

The first Qwen 3.7 Flash plain-control run on the public parallel-shards case
used the original byte-counted record format. One role counted Unicode
characters instead of UTF-8 bytes and produced an invalid ledger; another
mistook “add an issue to a document” for a request to edit the source. The run
therefore failed the exact-fact and source-preservation checks. This was useful
diagnostic evidence, not evidence that plain Markdown collaboration cannot
work.

The control was changed generally, before another model call: `Body JSON`
removed manual byte arithmetic, source-versus-fact wording became explicit,
format errors gained content-free recovery details, and harmless contextual
guide requests stopped failing. All no-model gates then passed again.

One exact, same-model, same-case, same-limit v2 retest passed every common
outcome, integrity, attribution, continuity, and recovery check while
preserving both source documents. It used 15 model calls, 17 tool round trips,
27.985 seconds of episode time, and $0.0019. The matched Margin v17 observation
also passed, using 8 model calls, 6 command round trips, 19.930 seconds, and
$0.0014. These are one-case resource observations, not a winner or a promotion
claim. The v1 failure and v2 repair are retained rather than rewriting history.

## Fresh-agent handoff probe

A second frozen pair used the public `agent_agent_handoff` repetition 2 with
two fresh processes and the same Qwen 3.7 Flash launch contract. Margin passed
every check, preserved the source, used 8 commands and 10 model calls, took
41.499 seconds, and cost $0.0016. The ordinary-Markdown control also transferred
the handoff, preserved the source, and completed the reply; it used 11 tool
round trips and 12 model calls, took 54.225 seconds, and cost $0.0016.

The frozen ordinary-Markdown scorer awarded only 50 on its outcome dimension
because the reply repeated the root record's audience. That routing field was
not requested by the task, did not change the facts, and is implicit for a
Margin reply. The scorer now normalizes only that exact inherited-audience
case, while still rejecting unrelated or enlarged audiences. The published
historical result is not rescored or rewritten; the correction applies only to
new runs.

The probe also found provenance omissions: the older public records do not
fully capture temperature, wall and upstream timeouts, or launch pacing, even
though both launch commands used the same values. New runs record all four.
Efficiency reports now require 37 hashed, content-free contract fields before
labeling a real-model pair `matched`; older evidence with an absent field is
labeled `insufficient-metadata`, and an actual difference names the setting
category. The handoff pair is therefore useful diagnostic evidence, not an
independently complete comparison and not a representation winner.

A fresh repetition then tested the repaired publisher prospectively with no
implementation change between cells. Both representations passed every common
check and preserved the source. Margin used 6 CLI actions, 8 model calls,
45.606 seconds, and $0.0015. The plain ledger used 15 tool actions, 15 model
calls, 63.771 seconds, and $0.0025; it recovered from one invalid ledger write
and one stale precondition. All 37 experiment-contract fields matched, and the
validated non-scalar report names no winner. The two public run artifacts are
`handoff-r3-margin-v17.run.json` and `handoff-r3-plain-v2.run.json` under
`Evals/marginbench/results/representation/v1/`.
