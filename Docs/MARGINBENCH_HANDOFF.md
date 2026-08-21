# MarginBench build-phase handoff

> **Historical snapshot:** This file records the August 18 build-phase handoff
> and intentionally preserves the evidence available at that time. It is not
> current release guidance. See `Docs/MARGINBENCH_PLAN.md` for the live state,
> current test counts, retained results, package status, and next work.

Status at 2026-08-18 11:03 ET: the primary benchmark track and its
compute-matched continuing-agent control are implemented, portable, tested,
packaged, and locally green. Two paid topology attempts each produced a valid
role-separated half and an infrastructure-invalid continuing half, so neither
supports a comparison. In the latest attempt the continuing agent reached the
exact result but encountered a recovered upstream 429; the frozen policy still
invalidates that episode.

## What exists

- A provider-independent benchmark core with six deterministic Markdown
  collaboration scenarios, exact executable scoring, private-keyed holdouts,
  bounded artifacts, paired comparison, diagnosis, and submission validation.
- A Prime Intellect Verifiers v1 adapter using the same task generator and
  scorer, with both in-process and served-environment fake-model rehearsal.
- A narrow agent gateway exposing only Margin, with bound actor identity,
  workspace confinement, command/byte/time limits, and privacy-minimized event
  records.
- A fail-closed live inference proxy that admits only the priced model and
  route, reserves pessimistic cost before forwarding, and stops future calls if
  provider-reported usage exceeds a reservation.
- Linux-compatible Margin core and CLI behavior tested on arm64 and x86-64,
  while the AppKit application remains macOS-only and isolated from benchmark
  dependencies.
- A public control contract for role-separated Margin, a single continuing
  Margin agent, confined plain Markdown, remote Margin-plus-shell, and a
  no-exchange floor. The first two profiles are fully tested and can execute;
  the representation and shell controls remain gated.

## Reproducible evidence

| Requirement | Evidence |
| --- | --- |
| macOS protocol correctness | 164 Swift tests passed |
| Linux protocol correctness | 112 tests passed in an architecture-pinned Swift container |
| Benchmark contracts | 63 passed in Prime's Python runtime; the rebuilt source package discovered and passed the same 63 tests with eight expected Prime-only skips |
| Deterministic reference quality | 6/6 scenarios scored 100 with safety passing |
| Hosted-boundary rehearsal | Both profiles passed 6/6 in process and 6/6 through the environment server; the concurrent-writer recovery path also passed 10/10 targeted served stress runs; 59 requests per full run, zero rejects, zero provider-bound violations, no paid inference |
| Clean distributable | Extracted source passed 63 tests with eight expected Prime-only skips; installed Intel Linux wheel passed self-test; package and CI reject sensitive/generated archive paths |
| macOS responsiveness | Final app warm launch median 286.610 ms, p95 289.237 ms; latest CLI help sample median 5.247 ms, p95 5.832 ms |
| Paid calibration | 21 benchmark attempts, 18 completed runs, 228 traced model calls, $0.0436 total wallet debit since opening; $199.9425 remains. No topology pair is valid or scored as a comparison. |

Run the local release gates from the repository root:

```sh
make test
make test-linux
make marginbench-test
make marginbench-preflight
make marginbench-package
```

The current benchmark implementation digest is
`24ad4dddc2e56a85c0d15a6419a01192a1edde572bbd72a5eb934412dd4dd536`.

Current benchmark packages:

- `build/marginbench-package/marginbench-0.1.0-py3-none-manylinux_2_35_x86_64.whl`
  — SHA-256
  `8454236f270122921a70e588280023663fcc36a60bba2fa5b5bcec638a8f93b0`
- `build/marginbench-package/marginbench-0.1.0.tar.gz` — SHA-256
  `b3b6a78e89ffa7c9e4ea6797923588cd178b4dd5ab7aecb7013d4780fe8653df`

Current macOS packages:

- `build/Margin-0.3.2-macOS-arm64.zip` — SHA-256
  `d051533f6c7cfda4307521d1668ca11449e99789a17bc94b9bc1f5377bcaf839`
- `build/Margin-0.3.2-macOS-arm64.pkg` — SHA-256
  `1ccec429adf23a1b680a4984e815e7d206256090e4198033eea2313a17ba2307`

The macOS artifacts are locally ad-hoc signed. The installer is not Developer
ID signed or notarized because no distribution certificate is available.

## Spend position

The opening balance was $199.9861 and the authenticated wallet now reports
$199.9425. Total debit is $0.0436. The original attempted topology pair used
$0.0019 inside the benchmark plus $0.0001 from a mistaken natural-language
balance probe. The separately authorized fresh pair used $0.0042. All repairs,
packaging, and served rehearsals between those attempts were model-free.

A complete 24-pair private study has a deliberately pessimistic provider
contract bound of $96.665312. With the tested per-job live cap it can enforce a
$2.40 maximum, but it should not run yet. The next paid checkpoint would be one
matched pair capped at $0.10 total, only after an implemented comparison
profile gives that pair a useful scientific question.

The first public pair could not be compared because the continuing half hit a
provider accounting bound. The repaired runner then priced eight possible
wrapper tokens, but the fresh continuing run encountered an upstream 429 before
recovering to an exact result. The frozen policy invalidates any such episode,
so the diagnostic 100 is not comparison evidence. Resolve that policy
prospectively with model-free fixtures before another paid attempt. The broad
study's $96.665312 provider-contract figure remains a disclosed worst case
rather than an expected-spend estimate.

A full no-spend schedule expansion confirms that both profiles contain 88
logical role runs. Role separation uses 88 model processes; continuation uses
48 processes with summed role limits. At identical limits their contract and
enforced maxima are exactly equal, so the comparison does not obtain a hidden
budget advantage from using fewer processes.

## Next work, in order

1. Define, before another run, whether a bounded provider retry that later
   succeeds is valid-but-disclosed or infrastructure-invalid. Add deterministic
   tests for recovered and terminal 429s; do not change the judgment on the
   run already observed.
2. Only after that policy is frozen should another matched public calibration
   be proposed. Inspect both redacted artifacts before planning private cases.
   The exact 24-case, 12/12-counterbalanced design remains frozen in
   `Docs/MARGINBENCH_CONTROLS.md`.
3. Implement and adversarially test the representation-neutral fact projection
   and visible Markdown interchange drafted in
   `Docs/MARGINBENCH_NEUTRAL_OUTCOMES.md`, then build the plain-Markdown and
   no-exchange controls. Do not grade them through Margin-specific annotations.
4. Implement Margin-plus-shell only in disposable remote sandboxes. It must
   never run against the host filesystem or inherit benchmark credentials.
5. Add an Environment Hub owner handle when public Prime publication is
   desired, then publish the already Hub-ready package. Local and packaged
   execution do not depend on that account setting.

## Deliberately unresolved

- The benchmark is a development snapshot with six task families, not yet a
  definitive public model ranking.
- The public hosted environment has not been published because the selected
  Prime team lacks a registry handle.
- The repository has no final public license yet; the benchmark card recommends
  Apache-2.0 for code/schemas and CC BY 4.0 for public development fixtures.
- Linux does not promise the full macOS ACL/xattr preservation contract.
- Public submissions are digest-bound and internally verified but are not yet
  signed by submitters or recorded in a transparency log.
