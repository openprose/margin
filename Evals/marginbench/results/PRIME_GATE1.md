# Prime Gate 1: cheap hosted smoke and first interface hill climb

Date: 2026-08-17 ET

Model: `qwen/qwen3.7-flash`

Scenario: one fixed public-development `human_agent_relay` episode

Harness: Prime Verifiers v1 null harness, one confined `margin` tool

Wallet debit across the phase: **$0.0048**

The purpose was not to estimate model quality. It was to verify the hosted path
and find obvious interface friction as cheaply as possible.

## Baseline

The hosted model authenticated, called the real CLI, and completed normally. It
scored 25 because the safety cap applied. It guessed a nonexistent top-level
`show` command, then created a new anchored thread instead of replying to the
human's existing thread, and never resolved that original thread. Source bytes,
document validity, authorship, and duplication checks remained correct.

Trace-reported cost was $0.0017 for 10 model calls. Raw traces were retained only
in the ignored local `runs/` directory.

## Candidate 1

Two general CLI changes were made:

- `show` became a safe alias for the existing read command;
- `comments add --help` now states that it starts a new thread and directs an
  answer to `comments reply`.

On the identical episode and model settings, the agent produced the exact reply
with the correct ID and authorship. It still guessed `cat`, and it stopped before
resolving the thread. The total remained 25 because the safety cap is deliberately
nonlinear, but the underlying behavior improved from the wrong graph operation
to the correct reply. Trace-reported cost was $0.0013 for 9 model calls.

## Candidate 2

The follow-up candidate adds `cat` as another safe read alias and makes every
reply receipt state the resulting thread status. While the thread remains open,
the response includes a structured next action for `comments resolve`, with
field references for the file, root ID, and returned revision.

The first identical hosted attempt encountered repeated provider 429 responses
before a trace or model action was produced. It was interrupted and recorded as
an infrastructure error, not scored as a model failure. A bounded retry after
the rate-limit window completed normally. The score rose from 25 to **80** and
the safety gate passed: the model used the safe read aliases, created the exact
reply in the correct thread, retained valid source, and stayed inside policy.
It nevertheless decided that an open thread was expected and stopped without
running `comments resolve`, despite the structured next action. One malformed
positional-message attempt also remained because the help usage line disagreed
with its option-only grammar.

Trace-reported cost for the valid retry was $0.0014 for 11 model calls. The team
wallet moved by the same $0.0014 across that retry.

## Candidate 3

The next local candidate corrects the reply help grammar to show `-m`,
`--message-file`, or `--stdin` instead of a positional message. Its help and
successful reply receipt now say plainly that replying never resolves the root
thread and that a task asking to resolve or close requires a separate
`comments resolve` call. This is a general workflow truth, not a benchmark-only
hint. It is locally verified and awaits one cooldown-separated hosted check.

## Cost reconciliation

Completed traces report $0.0044 in aggregate. The Prime team wallet moved from
$199.9861 to $199.9799, an exact phase debit of $0.0062. The $0.0018 difference
is left explicitly unreconciled; it may reflect the interrupted provider attempt
or billing aggregation. No stronger attribution is claimed without provider
evidence.

## What this already demonstrates

- The official Prime login, selected team, inference endpoint, Verifiers v1
  environment, model tool calls, Margin gateway, real executable, and exact
  scorer all work together.
- A sub-cent run exposed concrete CLI learnability failures.
- One small help/alias candidate changed the model from creating the wrong
  object to creating the correct threaded reply on the same case.
- The benchmark does not hide infrastructure errors or let partial success pass
  its safety gate.

This is development evidence only. It is one deterministic sample and must not
be presented as a statistically supported candidate win.
