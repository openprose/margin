# MarginBench iteration loop

Status: active operating procedure, 2026-08-21.

This document defines how Margin and MarginBench improve without confusing a
better tool with an easier test, a luckier model sample, or a repaired runner.

## One cycle

1. **Name one mechanism.** State the expected failure, the surface allowed to
   change, and the measures that should move. Keep the model, cases, topology,
   sampling, budgets, scorer, and safety policy fixed.
2. **Freeze the candidate.** Bind the Margin binary, manual, tool gateway,
   benchmark implementation, and settings by digest. Never change these inside
   a matched pair or reinterpret an earlier score under new rules. A shared
   episode ID is not enough: the published pair must independently match the
   model, temperature, token and turn limits, topology, task build, retry rule,
   and admission budget. Missing fields are reported as insufficient metadata,
   never assumed equal.
3. **Run free gates.** Require all Swift and Python contracts, the nine-scenario
   reference score of 100, both isolated environment-server rehearsals, schema
   validation, source preservation, and launch/startup checks.
4. **Buy the smallest useful observation.** Start with one public case on an
   inexpensive model. Cap every provider request and the complete run before
   authentication. Do not retry automatically.
5. **Classify before fixing.** A failure belongs to exactly one primary layer:
   product interface, benchmark task, scorer, model behavior, orchestration,
   provider infrastructure, or safety boundary. Infrastructure failures are
   incidents, never task scores.
   If the paid model work completed but publication failed, validate and
   cross-check the immutable `generated-summary.json` and `generated-run.json`
   checkpoints, then use `marginbench promote-checkpoint`; never buy the same
   model work again merely to repair bookkeeping.
6. **Use content-free diagnostics first.** Compare command names, option names,
   error codes, sequence shape, counts, timing, usage, and stop conditions.
   Inspect a private raw trace only when that evidence cannot distinguish the
   cause; never publish it.
7. **Change one layer.** Add a regression that reproduces the mechanism, make
   the smallest general correction, and repeat every free gate.
8. **Rerun the matched public case.** Treat the result as development evidence.
   If the target measure improves without a safety, correctness, latency, or
   cost regression, test a fresh generated case.
9. **Confirm privately only after stability.** Use rotating, mode-0600 keys and
   enough matched cases for the predeclared claim threshold. Public tuning
   never promotes a candidate by itself.
10. **Publish the whole shape.** Report quality, safety, time, tokens, cost,
    command count, invalid commands, and recovery separately. Audit the redacted
    bundle as one unit and reproduce its aggregate report from its published
    cells. A single weighted collaboration score is not a release decision.

## Order-neutral evidence

Counterbalancing is useful only if the evidence path is also neutral to which
arm happened to run first. Publish the same privacy-safe trace shape for both
arms, and bind each shape to its candidate identity. A binary digest is useful
corroboration but is not sufficient: two candidates may deliberately share one
binary while changing only the manual or settings. Diagnostics may use an
unlinked historical shape only when exactly one candidate is present; a
multi-candidate report must fail closed rather than guess.

The report may include both arms' shapes, but candidate-specific findings must
use only the selected candidate's evidence. Reversing the labels or operational
order must not change the behavior attributed to a candidate.

## Completion versus conversational closure

Separate durable task completion from a polite final sentence. If all required
work, workflow, recovery, safety, and source checks pass with a full outcome,
an answered final tool call at the turn ceiling is not a CLI budget defect. It
may still be relevant to harness UX or cost, but it must not outrank a real
product opportunity. A turn-limit stop remains a product-facing finding when
the durable outcome, required workflow, valid command use, or required recovery
is incomplete.

## Response-size evidence

Measure the bytes the agent actually receives, including its tool adapter, in
coarse privacy-safe buckets. Keep an independent direct CLI byte contract as the
deterministic gate. Optimize a brief view only after repeated traces show that
it crosses a meaningful bucket, and preserve executable next actions while
removing duplicated prose or metadata. Rerun startup and real-operation timing;
smaller output is not an acceptable trade for slower startup or hidden reads.

## Topology experiments

The experimental unit is one generated case completed under both topologies.
The case fingerprint, model, candidate, logical role budgets, provider policy,
and scorer must match. Each case follows the frozen `profileOrder`; separately
validated cells may be combined only when their normalized experiment contract
is identical. A report rejects missing or duplicate cells.

Use the dry-by-default crossover controller for real-model studies. It turns
the frozen per-case profile order into one serial schedule, checks the wallet
against the remaining enforced cap and reserve before each cell, refuses an
uncertain replay, and resumes only a verified contiguous prefix. Manual launch
bookkeeping is not part of the experiment anymore.

Fresh roles can help through parallelism, independent judgment, information
separation, or context hygiene. A continuing context can help through retained
working state and lower coordination cost. The same continuity that saves a
handoff can also cause phase interference: options, assumptions, or unfinished
plans from one role may leak into the next. Reports should describe that
mechanism rather than saying only that “multi-agent won.”

Two historical trace diagnoses illustrate the required level of care. In one
distributed-resolution case, the fresh reviewer successfully read the prior
work and posted the requested reply, but stopped before the clearly advertised
resolve action; the continuing agent completed both. That is evidence of a
phase-boundary stopping failure, not missing durable state. Margin now exposes
an atomic reply-and-resolve action so a model need not remember a second state
transition. In a specialist handoff, a fresh reviewer received the complete
prompt, untruncated source, and prior decision, yet copied two generic command
placeholders literally; the continuing agent filled them correctly. That is a
working-state reconstruction and action-template failure, not prompt loss or a
CLI write failure. Structured manual pages now mark templates non-executable
and list every required replacement explicitly.

For each apparent topology effect, check the causal chain in order: whether the
role received its exact prompt; whether the needed document and prior durable
work were complete; whether every read/write call succeeded; whether the agent
selected, filled, and sequenced the right action; and only then whether fresh
versus continuing context explains the difference. Corroborating traces from
an infrastructure-invalid run may suggest a mechanism but never count as a
replicate.

The complete v19 breadth run adds four operating lessons:

1. Pace every provider request, not just process launches. A six-second shared
   request interval completed 191 calls without the prior 429, and the pacing
   contract was identical for both topologies.
2. Treat a fresh role's first response as a real resource boundary. One author
   spent its complete response budget reasoning and never acted. Classify that
   separately from missing handoff data, malformed commands, and ordinary turn
   exhaustion.
3. Make recovery instructions executable. When a stage is stale, the response
   should name the exact retained stage, root, and safe refresh command. A bare
   error code forces a new agent to reconstruct state it never held.
4. Keep safety separate from completion. Both multi-file attempts were partial,
   but neither partially applied a transaction. That is valuable product
   behavior even when the task score is low.

The public trace-shape artifact now records final model finish reasons and
benchmark stop conditions alongside command/error counts. It remains content
free, which makes cold-start output exhaustion distinguishable from a real
turn-limit stop without publishing conversations.

The post-v19 candidate checks add three more rules. First, repeat a claimed
mechanism under an exact matched candidate pair: the old and new handoff CLIs
both scored 100, so the earlier contrast was stochastic rather than causal.
Second, never rescue a seemingly good task result from a provider-invalid cell;
the first staged candidate run completed the visible work but a rate-limit flag
kept it out of evidence. Third, use the smallest surviving mistake to choose the
next product change. In the valid replacement stage pair, the new candidate was
safe and exact but spent one failed call discovering that `stage list` required
a root it was already standing inside. The next CLI therefore made only that
argument optional, with upward workspace discovery, rather than raising the
turn budget or broadening the prompt.

The replacement's 70.625-point score gain, four fewer invalid commands, and
safe atomic result are useful mechanism evidence. With one public pair they are
not a population estimate, a promotion, or permission to retune the case.

Four matched pairs are calibration. Ordinary directional language requires at
least 20 valid pairs in the reported cell, all safety gates passing, and the
paired uncertainty interval clearing the frozen quality or speed threshold.

## Wide-directory response budgets

A single-document size check does not represent directory collaboration. Test
wide orientation separately with enough distractor documents and open work to
force bounded discovery. Freeze the directory shape, relevant target, work-item
distribution, command, process order, and candidate binaries before measuring.

Measure direct response bytes and elapsed time first, without a model. Run both
candidates in counterbalanced order after warmups, and retain medians and p95s.
Then assert that the compact response reports truncation and supplies executable
follow-up actions; a small response that silently omits work is a failure. When
an early stop avoids enumerating the remaining tree, describe the observed
omission count as a lower bound instead of an exact total.

Use the checked-in instrument for this first gate:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli wide-directory-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin
```

The command normalizes generated fixture metadata, validates every document,
alternates arm order, refuses malformed command output, verifies that neither
arm changed the workspace, requires actionable file/work/guidance coordinates,
and emits a schema-backed model-free report. Empty-but-stable output cannot
pass.

The opt-in `wide_directory_triage` scenario is the second gate. It places one
typed question beyond a four-file brief overview in a 16-document workspace
with 64 distractor threads. The exact reference must recover through
`inbox --brief`, make one atomic reply-and-resolve write, verify the thread, and
validate the document. Keep this scenario outside the historical default set
until enough paired evidence justifies changing the benchmark population.

Only after those free checks pass should one cheap matched agent case ask the
agent to orient, select the relevant document, make a durable change, and
verify it. The paid comparison must examine response-size bucket, model input,
path to first write, commands, invalid calls, correctness, and omitted-work
recovery. A lower byte count alone is not evidence that agents collaborate
better. Preserve old scenario versions rather than changing their directory
width, because historical scores must remain reproducible.

## Concurrent-write mechanism gates

Keep three questions separate: whether every update is preserved, whether a
normal collision is scored fairly, and whether an agent has to see and recover
from that collision. A correct store can still impose avoidable coordination
work; a convenient retry can still be unsafe if it crosses a source edit.

Use deterministic tests to force collisions and prove source preservation,
identity preservation, bounded retries, and fail-closed explicit preconditions.
Then use the model-free paired probe to measure what reaches the agent:

```sh
PYTHONPATH=Evals/marginbench python3 -m marginbench.cli concurrency-probe \
  --baseline-bin PATH_TO_BASELINE --candidate-bin build/margin \
  --repetitions 100
```

The probe starts both arms at the same barrier, alternates submission order,
and retains only aggregate call and conflict counts. Both arms must be exact,
safe, source-preserving, and free of invalid calls. The candidate must also use
four calls in every episode with no surfaced conflict. Baseline collision
frequency is descriptive, never a pass requirement: thread scheduling is a
source of measurement variation, not an oracle. Do not compare raw durations
from this contention probe as a launch-speed claim; use the separate
counterbalanced startup instrument for that question.

A model-free reduction in surfaced conflicts proves a mechanism improvement,
not better agent judgment. Buy a matched real-model case only when the research
question is whether the removed recovery burden changes completion, command
choice, tokens, or latency. Keep the benchmark's six-call safe-recovery path at
full efficiency so older binaries and real external conflicts are judged
fairly.

Natural model concurrency is not a reliable contention generator. In the first
public `suggestion_contention` pilot, both provider processes were concurrent,
but their inference latencies staggered all eight real writes. Both candidates
were exact and safe; the newer CLI used 23 rather than 25 visible interactions,
25 rather than 27 model calls, and 40.902 rather than 47.951 seconds, for scores
93.194 and 92.639. The complete pair cost $0.0107. Neither arm actually saw a
write conflict, so the small difference is calibration noise rather than retry
evidence.

That pilot also exposed two benchmark errors. Focused `suggest add --help`
requests were labeled as `suggest add`, inflating mutation counts, and an
unrelated explicit validation command obscured the mechanism under test. Help
is now classified separately, while durable list plus source read is the exact
verification route. The scenario now uses a disclosed benchmark-only lock
rendezvous for the first mutation. Five old-CLI reference cases then surfaced
2–4 stale-write results apiece and required 16–20 visible calls; twenty new-CLI
cases remained exact in the ideal 12 calls. The in-process and served fake-model
paths both still score 100 with two isolated traces.

The corrected public pair cost $0.0118. The old CLI surfaced one forced
`COLLABORATION_PRECONDITION_FAILED` result and recovered safely; the retrying
CLI surfaced no error. Both finished exact, safe, and source-preserving at
96.111, with 26 CLI calls and 28 model turns. The retrying CLI was 5.362 seconds
faster and $0.0004 cheaper, but the agent spent the saved recovery work on more
help, listing, inspection, and reading. This is positive mechanism evidence,
not evidence of lower total interaction cost. The next isolated variable is
therefore the built-in suggestion guidance: teach the shortest safe path for an
exact assignment, then rerun the same forced-contention pair. The
natural-scheduler pilot must never be reinterpreted under the corrected rules.

The first guidance-only pair then held the retrying mechanism fixed and changed
only the suggestion manual plus focused add help. It cost $0.0093. Both arms
were exact, safe, and source-preserving. The old guidance scored 96.944 with 23
commands, 25 model turns, 46.263 seconds, and $0.0051 reported cost. The new
guidance scored 97.222 with 22 commands, 24 model turns, 44.005 seconds, and
$0.0042 reported cost. Every new-guidance write used the exact `--expect`
precondition, while none of the old-guidance writes did.

This remains a diagnostic one-pair result, not a promotion result. The private
shape audit explains the modest gain: neither new-guidance role opened
`margin man suggestions`. Both opened global help and `suggest add --help`, then
still inspected, read, wrote four suggestions, listed, reread, and performed a
final inspect or review. The longer manual was therefore not the active teaching
surface. The next candidate should put a small structured exact-assignment path
directly in focused command help: read once, add the independent batch, trust a
matching success receipt, and list once; inspect or reread only after drift or
an external change.

That structured-help candidate did not reduce visible commands in its first
matched pair. The v47 arm scored 97.778 with 20 commands, 22 model turns,
58.632 seconds, and $0.0051; v48 scored 97.500 with 21 commands, 20 model turns,
42.292 seconds, and $0.0044. Both remained exact, safe, and source-preserving.
The candidate was materially faster and cheaper, but its one extra command made
the benchmark score slightly worse. Total pair cost was $0.0095.

The trace shape exposed a contradiction rather than model disobedience. The
scenario asks each role to inspect the final list and reread the literal source,
while v48 told each role to read once before writing. Every role therefore read
twice. For a complete exact assignment, `--quote` plus `--expect` already checks
the source inside the mutation and fails closed on drift. The correct fast path
is no preliminary read: add the independent batch, list once, then perform the
requested source read once after the batch. v49 corrects that guidance before
buying another matched pair.

The v48-to-v49 pair cost $0.0096. Both arms scored 97.500 with 21 commands and
23 model turns; v49 finished 1.906 seconds faster but cost $0.0002 more. Both
were exact, safe, and source-preserving, and both still performed four reads.
The product guidance is now semantically correct, but the benchmark prompt
contains a stronger generic instruction to “inspect the revision you act on.”
Suggestion creation does not act on a revision: its supplied exact text is the
source precondition. That global sentence biases every role toward an unrelated
pre-mutation inspection and masks the task-specific fast path. Keep v49, then
make the benchmark neutral: never invent a revision or source precondition, but
do not require a revision read for commands that do not use one.

v50 makes that benchmark correction. The shared rules now say to use an exact
revision or source precondition only when the task supplies it or the agent has
actually observed it, and to read current state only when the selected command
or outcome requires it. A regression protects the exact-assignment contention
task from regaining a mandatory preliminary read while retaining its required
final list and source verification. This changes the benchmark prompt digest,
so v46–v49 remain historical diagnostic evidence rather than controls for a
new comparison.

The correction passed 206 tests in each supported Python runtime, the
nine-scenario model-free suite at 100, the independent 85-role plain-control
audit, all 17 default fake-model role traces in both execution modes, and both
experimental contention traces in both modes. No paid model was invoked for
these gates. The next paid experiment must rerun both candidate surfaces under
this corrected benchmark rather than compare against an older prompt digest.

That corrected public pair cost $0.0087. v48 scored 98.056 with 19 commands,
18 model calls, 50.135 seconds, and $0.0038; v49 scored 98.333 with 18 commands,
20 model calls, 56.290 seconds, and $0.0049. Both were exact, safe, and
source-preserving. The one-case score gain of 0.278 and one saved command are
diagnostic only; v49 was slower and more expensive in this sample.

The command order is the causal evidence. Both v48 roles performed a source
read before their four writes. Neither v49 role did. One v49 role completed in
the intended shape—focused discovery, four writes, one list, one source read.
The other repeated its final list and read after reaching verification before
its concurrent peer had finished. v49 therefore fixes the preliminary-read
problem exactly, while exposing the next collaboration cost: an early finisher
has no cheap way to wait for a known set of peer contributions. Before changing
the CLI again, add a benchmark diagnostic that separates pre-write reads from
legitimate post-write convergence checks. Then evaluate an on-demand wait or
batch primitive without adding any work to ordinary CLI startup.

v51 adds that diagnostic without changing the score. For the exact-assignment
contention task, it examines each role only until its first `suggest add`,
allows local help and manual discovery, and fails if the role first reads
workspace or collaboration state. Reads after the first write remain visible in
the trace but do not fail the check, because they may be required to observe a
concurrent peer. The deterministic reference passes; a deliberately inserted
pre-write read preserves every correct outcome but fails this one diagnostic.
Both 206-test Python suites and the experimental fake-model workflow in both
execution modes pass. This gives the next CLI experiment a causal measure rather
than asking aggregate command count to stand in for two different behaviors.

v52 tests the higher-leverage alternative to waiting: one atomic same-file
suggestion batch. The CLI now accepts 1 to 256 exact assignments in bounded JSON,
validates every passage against one captured source, and commits the entire set
as one annotation revision. A bad anchor or changed source writes nothing;
stable IDs make exact replay conclusive; independent annotation-only races retry
inside the call. Cross-file work remains the job of immutable stages.

The benchmark now treats `suggest add` and `suggest batch` as equivalent valid
mutations and releases both through the same forced-contention rendezvous. Its
pre-write-read diagnostic recognizes either path. The fake model discovers the
new local help, submits four assignments in one batch, then performs the same
single list and source read. Both in-process and separate-server rehearsals
scored 1.0 for both collaborators with no paid model call. The cross-version
reference deliberately remains on individual additions so older candidates are
still solvable and comparable.

Free gates are green: 182 Swift tests; 206 Python tests in each supported
runtime; the experimental reference at 100; direct stdin execution; and both
served execution modes. In a counterbalanced 100-process sample, global-help
median was 6.217 ms for v51 and 6.245 ms for v52 (a 0.028 ms difference);
focused suggestion capability median was 7.027 and 7.082 ms (0.055 ms).
Candidate batch help measured 6.365 ms median / 6.954 ms p95. These are
scheduler-scale differences and show no material startup regression.

One fresh private Qwen matched pair then compared v51 and v52 under the same
forced collision. Both were exact, safe, source-preserving, and free of invalid
commands. v51 scored 97.778 with 20 commands, 22 model calls, 38.937 seconds,
and $0.0037 reported cost. v52 scored 98.056 with 19 commands, 21 model calls,
53.685 seconds, and $0.0051. The 0.278-point gain and one saved interaction are
diagnostic only; v52 was 14.747 seconds slower and $0.0014 more expensive. The
complete pair cost $0.0088, below its $0.10 hard cap, with zero retries or
provider-bound violations.

The role traces explain the mixed result. One v52 role opened batch help and
used one atomic batch; the other used four ordinary additions. The batch role
still made ten calls because an extra help lookup plus a second list/read pair
replaced the three writes it saved. The other v52 role made nine calls, saving
one preliminary source read. Both candidates still performed a state inspection
before writing, so the v51 diagnostic failed for all four roles. The mechanism
is safe and discoverable, but the progressive disclosure still makes agents pay
to learn the schema, and early finishers still repeat verification instead of
waiting for the known peer set. Before changing the product again, add explicit
non-scoring diagnostics for batch adoption and exactly-once post-write
verification; then put the complete bounded batch recipe in the first focused
suggestion surface rather than requiring a third help call.

v53 adds those measures without changing task instructions, outcomes, or score.
For each contention episode the scorer now records whether any role used an
atomic batch, whether every role did, and whether every role performed exactly
one successful list and one source read after its final successful write. The
last measure looks after the final write, so a legitimate collision-recovery
read is not mislabeled as redundant polling. Privacy-safe diagnostics rank
incomplete batch adoption and repeated post-write verification as concrete
interface experiments when those checks are present.

Deterministic regressions cover the old six-call-per-role reference, the ideal
three-call-per-role batch path, and an early finisher that repeats list/read.
Both 206-test Python suites and both fake-model execution modes pass; the fake
candidate uses batch for both roles and satisfies all three new checks. No
product binary changed and no paid model was invoked for v53.

v54 moves the complete atomic-batch recipe onto the first focused surface that
the real traces actually opened. `margin suggest add --help` now contains the
bounded v1 JSON shape, the required per-item fields, and the executable
`margin suggest batch FILE --items-file -` command. An agent with several exact
assignments no longer needs a third help lookup to learn the input contract.
The existing single-add route remains first and unchanged.

The fake-model rehearsal now starts from `suggest add --help`, adopts batching
only when that ordinary page contains both the schema and stdin command, and
falls back to four individual additions when an older binary lacks the recipe.
This mirrors the observed real-model discovery route without making old
candidates fail a speculative command. The reference remains at 100, and both
in-process and environment-server Prime rehearsals complete two collaborators
at full reward with no paid model call.

All 182 Swift tests and both 206-test Python suites pass, as do release,
package, signed-bundle smoke, and source-preservation checks. Detailed
suggestion capabilities remain bounded at 29,182 bytes, the brief projection
at 5,183 bytes, and focused add help at 3,222 bytes. Against the frozen v52
debug binary, a counterbalanced 200-process sample measured a 0.079 ms focused-
help median difference and a 0.115 ms global-help difference. The optimized
focused help remains about 6 ms. These are scheduler-scale differences, not a
speed regression or speedup claim.

One fresh private Qwen pair then held the batch implementation, task, model,
limits, and role layout fixed while comparing v52 with the first-help recipe.
Both arms were exact, safe, source-preserving, free of invalid calls, and
exactly-once in their post-write list/read verification. The complete pair
reported $0.0074, with a conservative proxy-accounted upper value of $0.016906
beneath the $0.10 cap; the private key copies were overwritten and removed
after independent submission verification.

The recipe did not improve adoption in this case. v52 scored 98.889 with 16
commands and one batch-using role. v54 scored 98.611 with 17 commands and no
batch-using role, although it finished 6.356 seconds faster. This is one
diagnostic pair, not a population result, but it falsifies the narrow claim
that a complete recipe on the add page is sufficient to make this model batch.
The self-contained help remains useful and safe; it is not an efficiency win.

v55 closes the measurement gap exposed by that result. Privacy-safe trace
shapes previously collapsed every local help request to `help`, hiding whether
an agent saw the page under test. They now retain only allowlisted static help
targets such as `help suggest add` and `help suggest batch`; unknown topics,
document paths, identifiers, prompts, and outputs remain absent. Reprocessing
the private traces showed that the v52 batch user opened global help, add help,
then dedicated batch help. Its peer opened add help and used four adds. In v54,
one role opened the new add-help recipe and still used four adds; the other
opened only parent suggestion help and used four adds. Both 207-test Python
suites pass the refined privacy and canonical-validation contract.

The next product experiment should therefore change the command affordance,
not add another paragraph. The leading usage on an `add` page still teaches a
single mutation, while batching requires switching verbs and constructing
stdin JSON. A unified multi-item add form can put the efficient path in the
primary usage block while preserving the existing single-add command and
atomic batch engine.

v56 implements that unified form without another mutation subsystem.
`margin suggest add FILE --items-file ...` dispatches to the existing bounded,
atomic batch engine; `margin suggest batch` remains an exact replay-compatible
alias. The multi-item form is the first add usage, parent suggestion help gives
the complete bounded schema, and the global example and manual use the same
verb. Benchmark telemetry normalizes both spellings to `suggest batch`, so an
interface rename cannot receive different protocol credit.

The deterministic reference remains at 100. Both in-process and environment-
server Prime rehearsals give full reward to both collaborators through the
unified spelling with no paid call. All 182 Swift tests and both 207-test Python
suites pass, including first application through `suggest add`, exact replay
through legacy `suggest batch`, changed-payload rejection, concurrent whole-
batch convergence, and old-binary fallback. Release, signed-bundle smoke, and
both distribution packages pass. Detailed suggestion capabilities are 30,007
bytes, below the 32 KiB bound; the brief form is 5,292 bytes.

A counterbalanced 3,000-process debug sample compared v56 with frozen v54.
Median differences were 0.171 ms for global help, 0.173 ms for parent suggestion
help, and 0.187 ms for add help. Absolute candidate medians were 5.583, 6.042,
and 6.119 ms respectively. Both binaries are exactly 8,015,488 bytes with equal
Mach-O segment sizes, so this is a recorded sub-millisecond process-layout or
scheduling effect, not evidence of a new startup path. The optimized CLI remains
2.7 MiB. No paid model was invoked for v56 yet.

One fresh private Qwen pair then compared v54's separate batch verb with v56's
unified add form. Both arms were exact, safe, source-preserving, and free of
invalid calls. v54 scored 96.667 with 24 commands, 25 model calls, 46.316
seconds, and $0.0046 reported cost. v56 scored 98.611 with 17 commands, 19
model calls, 37.912 seconds, and $0.0035. The pair reported $0.0081 total; the
proxy conservatively accounted $0.020153 beneath the $0.10 cap, independent
submission verification passed, and both private key copies were overwritten
and removed.

The command traces support the intended mechanism but also bound the claim.
Both v56 roles opened global help and add help. One then used the unified atomic
form in one write; the other inspected, read, and listed before making four
single additions. The batch role also listed twice after its write, so all-role
adoption and exactly-once post-write verification still failed their non-
scoring diagnostics. In the v54 arm neither role batched, one role exhausted
its turn allowance after extensive discovery, and both still committed every
required suggestion. This is a useful one-case win, not promotion evidence.

v57 fixes one telemetry inconsistency found while reading that pair. Gateway
events and the scorer already normalized `suggest add --items-file` to the
semantic batch operation, but private trace shapes showed the literal add verb.
Trace shapes now use the same safe semantic normalization. Reprocessing the
candidate trace yields exactly one `suggest batch`, four `suggest add`, and the
corresponding role-separated sequences without retaining stdin, paths, ids, or
document content.

v58 specifies the next experiment before changing the product. The contention
task already discloses the complete eight-id contribution set to both roles, so
an agent can wait for an exact durable predicate without hidden benchmark
knowledge. The task now permits one `suggest wait` call only when focused help
advertises it, retains `suggest list` as the old-binary fallback, and still
requires one literal-source read. Scoring accepts either convergence check;
non-scoring diagnostics separately report any-role and all-role wait adoption.

This contract is intentionally narrower than presence. A matching result means
only that the named suggestions are durably embedded in the selected Markdown
file. It does not claim that another collaborator is online, idle, finished, or
has no other work. Trace summaries retain the static `suggest wait` command but
discard every expected id and timeout value. The next product candidate should
therefore be a bounded on-demand process, with no daemon, startup polling, or
background initialization.

v59 implements that exact contract. `margin suggest wait FILE ID...` accepts a
complete public set of 1–256 distinct suggestion ids and a 0–120 second bound.
On macOS it registers a parent-directory event source before its first snapshot,
so atomic file replacement cannot be missed; a periodic recheck is only a
coalesced-event safety net. The process reads one file, starts no daemon, and
owns no watcher outside the explicit invocation. Success reports the observed
revision and source digest, up to 64 id/status pairs, and an explicit omitted
count. Timeout is a bounded temporary failure rather than a false success.

The exact real-CLI reference now completes suggestion contention at 100 in six
calls: each role makes one atomic batch, waits once for all eight public ids,
and reads literal source once. Both any-role and all-role wait diagnostics pass.
All 188 Swift tests and both 209-test Python suites pass, including atomic
replacement, non-suggestion exclusion, timeout, adversarial input bounds, and
the bounded success projection. Both supported fake-Prime execution modes also
complete 2/2 roles without paid inference.

Startup remains unchanged in the intended sense. A counterbalanced
same-toolchain release sample used 500 launches per arm for global help,
suggestion help, and add help. Median candidate deltas versus frozen v56 were
+0.029, -0.013, and +0.014 ms; p95 deltas were +0.079, -0.023, and +0.104 ms.
The stripped signed executable grows by 33,456 bytes. These are recorded as a
flat startup distribution and a small artifact cost, not as a speed claim.

The one justified private Qwen pair then tested discoverability without changing
the score contract. Both v59 roles used the named wait. Relative to frozen v56,
score changed 97.500→98.611, commands 21→17, model calls 23→19, prompt tokens
94,140→66,410, and reported cost $0.0046→$0.0033. Both arms were exact, safe,
source-preserving, and free of invalid calls. Candidate task duration rose from
42.335 to 43.947 seconds, so this is not latency evidence. The matched pair cost
$0.0079 total and the independently verified publication retained no prompts,
paths, ids, arguments, or document content. Both private key copies were
overwritten and removed afterward.

The trace shapes bound the conclusion. One v59 role used batch, wait, and the
required source read in six calls. The other used four individual additions,
then wait and read, but still listed once afterward. v59 therefore achieved
all-role wait adoption and removed four total commands, yet did not make the
successful receipt conclusive for every agent. This is useful one-case evidence,
not a promotion result; the frozen threshold remains at least 20 matched cases.

v60 corrects the benchmark diagnosis exposed by that trace. The old generic
finding still recommended adding a named wait whenever post-write verification
repeated—even if a successful wait was already in the sequence. A new non-
scoring check is vacuously true for roles that never wait, permits the separately
required literal-source read, and fails only when a role runs another successful
wait or list after its first successful wait. The corresponding finding now
targets receipt finality and next actions. This changes no correctness score and
does not retroactively rewrite the signed v59 evidence.

v61 isolates the wait mechanism without a model. Each arm starts with one
known suggestion; a peer adds the second after a controlled 200, 500, or 1,000
ms delay. The frozen pre-wait binary polls `suggest list`, while the candidate
runs one `suggest wait` for the same two public ids. Twelve paired,
counterbalanced trials completed exactly and preserved both the comment graph
and logical Markdown. The polling arm made 115 measured convergence calls; the
wait arm made 12, exactly one per trial. Median call savings increased from four
at 200 ms to fourteen at 1,000 ms. Candidate median end-to-end time was 9.753
to 51.515 ms lower, but duration is descriptive and not a pass criterion.

The independently validated aggregate is retained at
`Evals/marginbench/results/convergence/v61-model-free.json`. It contains no
paths, ids, bodies, or model data, and its schema recomputes the case-set digest,
histograms, summaries, per-delay totals, comparisons, and pass flag. This
establishes that one blocking predicate causally removes visible polling. It
does not establish that models will trust the receipt, and it does not justify
presence or general-completion claims.

v62 separates receipt trust from wait mechanics. The successful JSON result now
sets `receiptConclusiveForNamedIDs: true` and
`immediateRecheckRequired: false`. Its notice says that the receipt is
conclusive for those ids at the reported revision and names the only exception:
a known later file mutation. It explicitly tells agents not to run another
`suggest list` or `suggest wait`, while retaining the narrower boundary that the
receipt proves neither collaborator presence nor unrelated work. Timeout
results carry the inverse internal state and continue to fail temporarily.

Focused help and the suggestions manual use the same language, and the only
next action is an optional literal-source read that explicitly does not recheck
the ids. The real CLI contract test exercises the complete add→wait JSON path,
not merely static copy. Suggestions capability output remains bounded at 20,633
bytes compact, 32,676 bytes pretty, and 7,784 bytes in the brief projection.
Both fake Prime modes completed the two-role contention rehearsal at 100, and
the nine-scenario deterministic self-test remained 100, with no paid model.

The signed release digest is
`7c2df67830f9a99de5f764b2092f3876ae69198f7b64943e4370537e69a6c358`;
its CLI size is unchanged at 2,842,784 bytes. In 500 counterbalanced launches
per path versus v59, median deltas were -0.054 ms for global help, -0.036 ms for
suggestion help, and -0.050 ms for wait help. P95 deltas ranged from -0.081 to
-0.001 ms. These are flat scheduling-scale results, not speedup evidence. No
additional paid run is warranted until a fresh receipt-trust study is planned.

v63 hardens that planned study before interpreting another model result. The
first fresh private arm stopped safely after Prime reported 2,094 completion
tokens for a request whose visible generation limit was 1,800. Of those, 1,615
were hidden reasoning tokens. The episode's document outcome happened to be
exact, but the run is censored infrastructure evidence: the old plan had frozen
only eight extra provider tokens, the spend proxy latched closed, the candidate
arm never started, and no retry occurred. The account-wide wallet moved by
$0.0014. Both temporary holdout-key copies were overwritten and removed.

The failure exposed an ambiguous budget field rather than a Margin product
failure. The harness now separates visible answer tokens, a source-backed
hidden-reasoning ceiling, and a small provider-wrapper allowance. Alibaba
documents `thinking_budget` for the Qwen 3.7 series but does not document 4,000
as Qwen 3.7 Flash's default. MarginBench therefore freezes 4,000 as its own
conservative study ceiling, inserts that ceiling into the upstream request, and
prices the complete 1,800 + 4,000 + 10 token bound before forwarding. Unknown
models receive no guessed reasoning contract. Any supplied larger thinking
budget is rejected locally, and any provider usage above the combined bound
still latches the run closed.

Model-free adversarial coverage reproduces the observed 2,863-token completion
shape under a 1,800-token visible limit, verifies the injected thinking budget,
and rejects an over-ceiling request. Infrastructure classification now
distinguishes the local proxy's intentional HTTP 429 from Prime's documented `rate_limit_exceeded`
response, so a budget stop is no longer mislabeled as provider throttling. The
native suite passes 189 tests, both supported Python suites pass 217 tests, and
the existing publication audit remains green. No second paid run has been
started; Prime acceptance of the vendor extension remains the first explicit
capability check in a new run identity.

A public deterministic dry run then exercised the same two-job controller
without a holdout key or model call. Its frozen plan shows 1,800 visible tokens,
4,000 reasoning tokens, ten wrapper tokens, and a $0.05 hard study cap; dry-run
mode created neither a work directory nor a publication directory. Release
smoke passed, and the unchanged CLI remains 2,842,784 bytes with SHA-256
`7c2df67830f9a99de5f764b2092f3876ae69198f7b64943e4370537e69a6c358`.

v64 turns that first capability check into a separate, reusable admission
receipt instead of spending a full agent episode to discover a provider-shape
problem. The probe is dry-run by default. Live mode permits one fixed public
prompt, one request, zero agent processes, and zero retries; its current maximum
reservation is $0.00097682 beneath a $0.001 hard cap. It stores no prompt or
response text. Its schema-backed result contains only status, usage counts,
bounded checks, timing, and an account-wide wallet observation.

A paid reasoning study now refuses to start without a passing receipt from the
last 24 hours that matches the exact model, reasoning ceiling, and evidence
source. Direct, paired, and crossover controllers freeze the receipt's digest
into their plans and copy the exact bytes into private frozen inputs. The check
is intentionally modest: a successful response shows only that the gateway
returned success for a request containing the reasoning setting. It cannot
prove that an intermediary preserved the setting or that a provider will honor
it later, so the local proxy still prices and bounds every study request.
Model-free tests cover fake acceptance and rejection, censored error bodies,
tampered reservations, stale and mismatched receipts, missing-receipt refusal,
and digest propagation. Both supported Python suites pass 222 tests. No paid
request was made in this iteration.

v65 uses that admission path once and then resumes the frozen receipt-trust
comparison on a fresh private case. The probe returned success for one request
containing the 4,000-token thinking setting. Prime reported 17 input tokens and
189 completion tokens, including 183 reasoning tokens. No request was rejected
or retried, no prompt or response text was retained, and the account-wide wallet
moved by $0.0001. Its independently validated receipt has SHA-256
`86948bb5c58b423c223f795d89f7e13b298bb57005b25695adea2415234590d4`.

The matched plan then froze that receipt, one private suggestion-contention
case, six-second request pacing, a $0.025 proxy cap per job, and a $0.05 study
cap. Each job was released separately and inspected before the next. Both
completed without retry or infrastructure error, preserved every source byte,
used only valid commands, and produced the complete durable outcome. The v59
baseline scored 100 in 11 commands and 13 model calls. The v62 candidate scored
99.444 in 14 commands and 16 model calls. Total trace-reported cost and
account-wide debit were $0.0065; the proxy-accounted upper bounds summed to
$0.012609.

The intended receipt mechanism did not explain the difference. Both versions
used one named wait per role and neither listed or waited again afterward, so
receipt trust was already perfect in the baseline. The extra work came from one
v62 role that opened the focused batch-teaching help but still issued four
individual suggestions; its peer used the atomic batch. Both v59 roles batched.
This single pair rejects a benefit claim for the stronger receipt wording on
this case, but it does not establish a v62 regression. The next benchmark turn
must expose per-role teaching, batch adoption, and receipt-trust counts before
another CLI change or larger paid sample. Both private-key copies were
overwritten and deleted after the redacted submission reproduced successfully.

v66 turns that interpretation into a reusable measurement instead of leaving it
as a manual trace reading. Content-free trace-shape reports now separate five
questions for every suggestion-contention role: Was focused batch teaching seen
before the first write? Was atomic batch adopted? Were individual additions
used instead? Was a named wait observed? Was its success trusted or followed by
another list/wait? The report retains only fixed command categories and counts;
it still excludes arguments, bodies, paths, identifiers, prompts, and results.
Schema and semantic checks bind every subset, the wait partition, each role, and
the global totals. The diagnostic report carries the same evidence alongside an
incomplete-batch finding, so the proposed next experiment can distinguish
discoverability from adoption.

Reprocessing the v65 traces confirms the intended separation. Both v59 roles
saw the focused batch teaching, both batched, and both trusted their wait. Both
v62 roles also saw the teaching and trusted their wait, but only the reviewer
batched; the author chose individual additions. That makes another wording-only
change poorly motivated. It points instead to the cost of expressing the batch
input through the agent tool boundary. Both supported Python environments pass
224 tests, including privacy and semantic-tamper checks. No paid request was
made for v66.

v67 changes the cost of expressing the operation rather than adding another
instruction. `margin suggest batch FILE` now reads standard input by default
and accepts the exact bare assignment array already present in the benchmark
brief. An agent no longer has to add a schema/version envelope or choose
`--items-file -`. Saved files and the versioned envelope still work, as does the
unified-add compatibility spelling. All paths reach the same bounded atomic
engine: every anchor is checked against one source snapshot, one bad item writes
nothing, annotation-only races retry internally, source drift fails closed, and
stable IDs make matching replay conclusive.

The change remains off the startup path. The signed CLI is 2,842,800 bytes, 16
bytes larger than v62. Suggestion capabilities encode to 20,303 bytes compact
and 32,346 bytes pretty, within the 32 KiB contract; focused add and batch help
are 3,471 and 1,992 bytes. In 500 counterbalanced launches per arm, v67 minus
frozen v62 median differences were -0.004 ms for global help, -0.036 ms for add
help, and -0.049 ms for batch help. These are scheduling-scale differences, not
speed claims, and show no regression. All 189 Swift tests, both 224-test Python
suites, the nine-scenario reference, isolated agent controls, signed release,
and retained publication audits pass. No paid request was made while building
or validating v67.

v68 froze v62 and v67 against one new private suggestion-contention case under
the same Qwen model, reasoning bound, request pacing, $0.025 per-job cap, $0.05
study cap, and $190 wallet floor. The v62 arm completed exactly and safely at
97.5: 21 valid commands, 23 model calls, atomic batching by both roles, named
waits by both roles, and one avoidable recheck after a conclusive wait. Its
trace-reported cost and account-wide wallet movement were both $0.0056.

The v67 arm did not produce evidence. Prime returned an upstream error after 18
forwarded requests; the summary is `infrastructure_error`, the pair controller
made no retry or comparison, and the account-wide wallet moved by another
$0.0029. Its partial command outcome is neither a candidate score nor batch
adoption evidence. The incident did expose a benchmark accounting weakness: a
transport-uncertain request retained its reservation as indefinitely in flight,
and the proxy remained open to later requests until a separate limit stopped
them.

v69 makes the first uncertain request terminal for paid forwarding. A transport
failure, oversized response, malformed success body, or non-2xx provider
response now keeps the request's complete admitted upper bound, moves it out of
the in-flight set, records one `uncertainRequestCount`, and latches the local
proxy closed. Any later model retry is rejected before it can reach Prime. The
validator binds settled, uncertain, and outstanding counts to total forwarded
requests and treats an uncertainty latch as infrastructure rather than product
or model evidence. A real loopback 503 regression proves that exactly one
request reaches the upstream server, the second stops locally, no reservation
remains outstanding, and the full conservative first-call bound remains
charged. Both supported Python environments pass 227 tests. No further paid
request was made while implementing this hardening.

v70 re-established the one-request provider contract after that hardening. The
fresh probe completed with 17 prompt tokens, 181 completion tokens including
175 reasoning tokens, no retry, no rejected request, no uncertainty, and no
outstanding reservation. The account-wide wallet moved $0.0001. Its receipt
digest was frozen into a wholly new private study rather than being reused to
resume the censored attempt.

v71 then produced the first complete v62-versus-v67 comparison. Both arms were
exact, safe, source-preserving, and free of invalid commands. The bare-array
candidate improved 97.5 to 98.333, reduced commands from 21 to 18 and model
calls from 23 to 20, finished 17.198 seconds sooner, used 44,394 fewer prompt
tokens, and reduced trace-reported cost from $0.0058 to $0.0044. This is one
matched private case against a 20-pair promotion requirement, so it is useful
mechanism evidence rather than a release or population claim.

The content-free role trace explains the gain and its limit. The candidate
author opened the suggestion workflow, passed all four supplied assignments to
one atomic batch, waited once, and stopped after the required source read. The
candidate reviewer opened only focused single-add and wait help, then issued
four individual additions and rechecked after waiting. Thus both roles saw
relevant teaching, but only the role that reached the parent workflow adopted
the bare batch. More instruction is not the next experiment: the atomic form
should instead become the lowest-friction interpretation of `suggest add`
itself. The verified submission id is `sha256:042a1394…`; it publishes no raw
trace, prompt, path, identifier, document content, or key. Both private-key
copies were overwritten and deleted after verification.

The run also exposed an operator-path bug. The first publication location
overlapped the controller's private redacted-job directory, so completed jobs
could not be finalized there. The controller correctly resumed without another
model call when finalization moved to a sibling directory, but its error was too
late and too generic. v72 now rejects any publication location that overlaps
raw, redacted, or frozen inputs before it creates work state, reads the wallet,
claims a paid start, or launches a child. A collision regression and the normal
pause/resume/replay path both pass.

v73 removes the remaining verb switch on the reviewer’s actual discovery path.
When `margin suggest add FILE` receives no single-item selector flags, it now
reads the supplied bare item array from standard input and uses the same bounded
atomic engine as `suggest batch`. Any quote/range, replacement, message, stable
item id, audience, or explicit target path continues to select the existing
one-item form. Missing-target mistakes fail before stdin is read. The legacy
batch spelling and saved/versioned input remain exact aliases, so this is a
smaller front door rather than a new mutation protocol.

The benchmark gateway records that no-flag add form as one semantic batch, and
the model-free agent rehearsal now starts from the focused add page and stays on
the add verb. Both its in-process and environment-server paths pass on the
suggestion-contention case. The full gate passes 189 native tests, 228 tests in
each supported Python runtime, the nine-scenario reference at 100, neutral
production isolation, signed release, privacy checks, and retained-publication
audits. The CLI is still 2,842,800 bytes. Suggestion capabilities are 20,536
bytes compact and 32,579 pretty, under the 32 KiB contract.

In 500 counterbalanced launches per arm and path against the frozen v67 binary,
candidate-minus-baseline median deltas were +0.006 ms for global help, -0.042
ms for add help, -0.022 ms for batch help, and +0.040 ms for suggestion
capabilities. P95 deltas ranged from -0.075 to +0.145 ms. These are scheduler-
scale movements and show no startup regression. The exact signed candidate
digest is `6ef13fccb2dc8fdea4465d7d01e8a9e97c2d7fb5043903920073b3653ad72985`.

v74 tested that one change on a wholly new private case against frozen v67.
Both arms were exact, safe, source-preserving, and free of invalid commands.
v73 improved 99.444 to 99.722, reduced commands from 14 to 13 and model calls
from 16 to 15, finished 4.387 seconds sooner, used 1,266 fewer prompt tokens,
and reduced reported cost from $0.0034 to $0.0033. The pair reported $0.0067
total model cost and identical account-wide movement against a $0.013419
conservative proxy upper sum.

The content-free mechanism trace confirms the intended causal step. v67 batched
in one role and issued four individual additions in the other; v73 performed
one semantic batch in both roles. Both v73 roles trusted the named-wait receipt.
The candidate’s remaining efficiency loss was orthogonal: one role inspected
before writing and reviewed after the required source read. This is a better
next measurement target, but one observation is not enough to justify more CLI
copy or a larger paid run. The verified submission is `sha256:2e41eba…`; it
retains no private document, prompt, path, identifier, raw trace, or key. Both
private-key copies were overwritten and deleted after reproduction.

v75 makes the remaining behavior measurable without reopening the private
content boundary. Suggestion-contention results now distinguish state reads
before the first write, the required one convergence check plus literal source
read after the final write, and any successful state read beyond that pair.
These are diagnostic checks and content-free counts, not new correctness credit.
The two new fields are optional in the v1 schemas so every sealed report made
before v75 remains valid.

Reprocessing the sealed v74 traces confirms the structural observation. The v67
roles had zero preliminary and zero extra post-write state reads. In v73, one
role had one preliminary inspect and one extra review after its successful named
wait and required literal source read; its peer had neither. The diagnostic now
names `extra-postwrite-state-reads` and recommends replication before any CLI
copy experiment. Both supported Python runtimes pass 229 tests. No private text,
argument, path, identifier, or tool result entered the report, and no further
model request was made.

## Spend ladder

Every paid plan records both the conservative provider-contract maximum and a
smaller enforced live cap. Observed historical cost is planning evidence, not a
safety bound.

1. Free deterministic and fake-model gates.
2. One public cell on the cheapest useful model.
3. Its matched topology or candidate cell.
4. A four-family public breadth slice.
5. Fresh public repetitions of only stable mechanisms.
6. Rotating private confirmation with at least 20 matched cases.
7. A broader model matrix after task and runner behavior are stable.

Stop a campaign after any unsafe result, provider-bound violation, contract
drift, missing artifact, or unexplained scorer behavior. Preserve the redacted
incident receipt and require a new explicit run identity after correction.

## Promotion checklist

- Candidate and benchmark digests are frozen.
- Free gates pass in both supported Python runtimes and the pinned Swift
  toolchains.
- The exact plan, profile order, limits, price inputs, retry policy, and total
  live cap were fixed before inference.
- Every run and summary validates independently.
- The complete redacted bundle passes `marginbench audit-crossover` and its
  aggregate report reproduces from the published cells.
- Raw prompts, traces, paths, IDs, document content, and keys are absent from
  public artifacts.
- All candidate cases are safe and source-preserving.
- The intended metric improves on matched cases without a material regression
  in another primary dimension.
- Public evidence is confirmed on rotating private cases.
- The sample threshold and uncertainty rule are satisfied.
- App launch and CLI startup remain within the published performance envelope.

If any item is false, the result can guide another iteration but cannot promote
the product or support a leaderboard claim.

The checkpoint promotion command is intentionally narrow and idempotent. It
accepts only a supported summary/run schema pair, requires exact candidate,
model, episode, check, safety, source, and cost agreement, validates both files,
and creates only absent output files. An existing byte-identical artifact is a
safe replay; other existing data fails closed.
