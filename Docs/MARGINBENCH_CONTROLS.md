# MarginBench comparison-control contract

Status: design frozen for implementation; only
`role-separated-margin-only-v1` is currently runnable.

MarginBench needs controls to answer four different questions without mixing
them together:

1. Does splitting work across agents help compared with one continuing agent?
2. Do Margin's durable collaboration primitives help compared with ordinary
   Markdown file access?
3. Does a narrow tool surface help compared with a general shell?
4. How much of each task is possible when collaborators cannot exchange state?

These are separate benchmark tracks. A score from one control profile must not
be pooled with another profile or presented as a model-quality delta.

## Rules shared by every control

- Use the identical hidden case fingerprint, source files, scripted human
  events, model version, sampling settings, retry policy, and candidate build.
- Freeze the control profile in the study plan before ordering runs.
- Counterbalance candidate order inside each control profile.
- Score final files and safety with deterministic checks. Never use an LLM
  judge to translate one representation into another.
- Record collaborator roles separately from actual model-process count. Cost
  bounds use model processes and permitted calls, not the number of fictional
  roles in the task.
- Keep scores from profiles with different comparable dimensions in separate
  tables. Missing dimensions are not zero and must not be averaged as zero.
- A control is not runnable merely because code exists. It becomes runnable
  only after the local reference, adversarial, served-environment, privacy,
  budget, and artifact-validation gates below all pass.

## 1. Single continuing agent using Margin

Profile: `single-agent-margin-v1`.

Purpose: isolate the effect of splitting a task across collaborators while
retaining Margin, the same role briefs, and the same durable workspace.

Definition:

- One model process and one continuing transcript handle every role phase.
- The environment opens a promptless interaction, then sends the existing role
  briefs as separate user turns in deterministic phase and seat order. It does
  not rewrite or combine the briefs.
- Before each turn, a trusted phase controller binds the Margin gateway to that
  role's original actor ID, name, type, and seat. The model cannot select or
  override the identity. Writes therefore retain the same authorship that the
  role-separated run would have produced.
- Scripted human and external-edit events run at the same phase boundaries.
- Roles that are concurrent in the primary profile become serial in their
  stable generated order. That loss of parallelism is part of the topology
  being measured and is disclosed.
- The trace has seat `agent`; the result separately records the logical actors
  whose turns were executed.

Compute matching:

- For a two-role episode, the single process receives the sum of the two role
  turn, output, and total-token ceilings. This is the primary control because it
  holds the maximum generated work approximately constant instead of quietly
  halving compute.
- The provider-contract cost bound uses one process and the summed call limit.
  It is not copied from the two-process role count.
- A process-normalized variant may later use one role's budget, but it requires
  a distinct profile ID and cannot be pooled with the compute-matched control.

Required implementation changes:

1. Add a promptless `MarginBenchTask` projection and use Verifiers' continuing
   interaction API for phase turns.
2. Add a phase-bound gateway identity controlled only by the environment.
3. Separate `logicalRoles`, `agentProcessCount`, and trace seats in plans and
   run validation.
4. Make study pricing derive calls from the control topology.
5. Keep the existing exact scorer; annotations, actor IDs, source, and final
   status are representation-identical.

Release gates:

- All six deterministic reference cases score 100.
- A malicious role prompt cannot retain the previous actor or choose the next
  actor before the controller advances the phase.
- Concurrent-review serialization cannot lose either contribution.
- Trace aggregation produces one trace and the correct logical actor set.
- Dry plans and live proxy reservations charge one process with the summed
  call budget.
- In-process and served fake-model matrices both pass before one public paid
  cell is proposed. That first cell may reserve at most $0.02.

## 2. Role-separated agents using ordinary Markdown files

Profile: `role-separated-plain-markdown-v1`.

Purpose: measure what Margin's durable comments, identity, inbox, suggestions,
handoffs, staging, and recovery add beyond confined file access.

Tool boundary:

- `workspace_list`: bounded directory names and file metadata.
- `workspace_read`: bounded line or byte slices plus a content digest.
- `workspace_write`: one complete-file compare-and-swap replacement.
- No shell, Git, network, hidden fixture, Margin executable, atomic multi-file
  batch, comment protocol, or implicit retry.

The file gateway must enforce the same path confinement, byte limits, timeout,
event redaction, and actor-seat binding as the Margin gateway. A failed
compare-and-swap is returned as data and never silently retried.

The current annotation oracle cannot grade this control fairly. Before the
profile runs, every scenario needs a representation-neutral outcome contract:

- exact source edits and forbidden edits;
- exact decision, question, issue, task, suggestion, or handoff facts;
- actor attribution when the chosen representation carries it;
- whether the next role can discover the prior role's durable work from files
  alone;
- all-or-none file state and conflict recovery; and
- safety, source preservation, command count, latency, tokens, and cost.

The benchmark may specify a small plain-Markdown reporting template, but it
must be disclosed as part of this control and must not reproduce Margin's hidden
protocol. A parser must deterministically grade it. Free-form semantic judging
is not acceptable.

Release gates:

- A reference writer and parser cover every scenario without Margin.
- The neutral oracle gives identical outcome/integrity credit to equivalent
  Margin and plain-Markdown facts.
- Protocol-specific dimensions are omitted, not treated as failures.
- Concurrent stale writes, path escape, symlink escape, oversized files, and
  partial multi-file state have adversarial tests.
- Both role processes remain transcript-isolated.

## 3. Role-separated Margin agents with a shell

Profile: `role-separated-margin-shell-v1`.

Purpose: measure whether a broad action space helps or distracts compared with
one narrow Margin tool.

This profile must never run on the host. Each role needs its own disposable
remote sandbox containing only:

- the role brief;
- the public workspace view needed by the task;
- a pinned Margin executable;
- a bounded channel to the shared workspace service; and
- the ephemeral live-proxy capability.

It must not contain the holdout key, scorer, oracle, other role brief, Prime
credential, repository, host filesystem, ambient tools, or raw traces from
another role. Network access is denied except for the inference proxy and the
shared workspace channel. The sandbox is destroyed after the role and the
controller verifies that no active runtime remains.

Shell commands require a separate redacted event type. Command names, exit
status, byte counts, duration, and policy result may be retained; arguments,
environment, file bodies, and output content may not be published. Direct
credential, harness, hidden-fixture, and host-path access are hard safety
failures.

Release gates:

- Prime-managed sandbox setup/teardown passes with no model and a worst-case
  cleanup cost bound.
- Adversarial shell probes cannot read any hidden or host material.
- The shared workspace preserves the same atomic and conflict semantics as the
  primary profile.
- A fake shell agent completes every reference case before a paid proposal.
- Paid shell research needs its own literal confirmation and cannot share the
  primary leaderboard.

## 4. No-exchange floor

Profile: `role-separated-no-exchange-v1` (cataloged but not runnable).

This is a research floor, not a normal leaderboard. Each role receives its
brief and an independent copy of the initial public files. It receives no prior
transcript, shared writes, handoff file, comments, or later role output. Final
state is graded per role against only the representation-neutral checks that
role could satisfy alone.

Do not assign a single aggregate score across all six scenarios until those
per-role neutral checks exist. Otherwise the control merely encodes that a
handoff task is impossible without a handoff, which is true but not informative.

## Implementation order

1. Implement the single continuing-agent profile locally because it reuses the
   exact Margin representation and scorer.
2. Add topology-aware plan, cost, trace, and schema fields; retain backward
   compatibility for existing role-separated artifacts.
3. Pass all local and served fake-model gates, then consider one $0.02-capped
   public single-agent calibration cell.
4. Define and test neutral outcome projections before writing the plain-file
   gateway.
5. Build the no-exchange floor from those neutral per-role checks.
6. Implement the shell profile only in disposable remote isolation.

## Promotion rule

A control profile moves from `specified-not-runnable` to `implemented` only in
the same commit that adds its complete tests, cost accounting, schema support,
served preflight, privacy proof, and documentation. Until then, every CLI and
paid runner must continue to refuse it before creating work state or spending
credit.
