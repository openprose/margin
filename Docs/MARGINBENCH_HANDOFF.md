# MarginBench build-phase handoff

Status at 2026-08-18 06:17 ET: the primary benchmark track is implemented,
portable, tested, packaged, and ready for further no-model development. No
additional paid run is justified before the next comparison profile passes its
local release gates.

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
  no-exchange floor. Only the fully tested first profile can execute.

## Reproducible evidence

| Requirement | Evidence |
| --- | --- |
| macOS protocol correctness | 164 Swift tests passed |
| Linux protocol correctness | 112 tests passed in an architecture-pinned Swift container |
| Benchmark contracts | 51 passed in system Python and 51 passed in Prime's Python runtime |
| Deterministic reference quality | 6/6 scenarios scored 100 with safety passing |
| Hosted-boundary rehearsal | 6/6 passed in process and 6/6 through the environment server; 59 requests each, zero rejects, zero provider-bound violations, no paid inference |
| Clean distributable | Extracted source passed 51 available tests with six optional Prime skips; installed Intel Linux wheel passed self-test |
| macOS responsiveness | App warm launch median 288.431 ms, p95 326.421 ms; CLI help median 5.132 ms, p95 5.800 ms |
| Paid calibration | 17 attempts, 16 completed runs, 193 model calls, $0.0374 observed debit; $199.9487 remains |

Run the local release gates from the repository root:

```sh
make test
make test-linux
make marginbench-test
make marginbench-preflight
make marginbench-package
```

The current benchmark implementation digest is
`1f70155a6cada26b8c51ecbb4c7e59dbb476ffb9552ef3a9cb7e616c096e0c8e`.

Current benchmark packages:

- `build/marginbench-package/marginbench-0.1.0-py3-none-manylinux_2_35_x86_64.whl`
  — SHA-256
  `d6b57497a55a9b8cef6718ff3afa156297e936e9ff83849f26a44294ce5f2f76`
- `build/marginbench-package/marginbench-0.1.0.tar.gz` — SHA-256
  `ecd8065c151dd4a4a1e00ca81378dde5bcd4a3a83e4ec18f9cfa11402d9a9457`

Current macOS packages:

- `build/Margin-0.3.2-macOS-arm64.zip` — SHA-256
  `d051533f6c7cfda4307521d1668ca11449e99789a17bc94b9bc1f5377bcaf839`
- `build/Margin-0.3.2-macOS-arm64.pkg` — SHA-256
  `1ccec429adf23a1b680a4984e815e7d206256090e4198033eea2313a17ba2307`

The macOS artifacts are locally ad-hoc signed. The installer is not Developer
ID signed or notarized because no distribution certificate is available.

## Spend position

The opening balance was $199.9861 and the authenticated wallet now reports
$199.9487. The build phase used $0.0374. All later hardening, packaging, Linux
verification, and served rehearsals were model-free.

A complete 24-pair private study has a deliberately pessimistic provider
contract bound of $96.662016. With the tested per-job live cap it can enforce a
$2.40 maximum, but it should not run yet. The next paid checkpoint would be one
matched pair capped at $0.10 total, only after an implemented comparison
profile gives that pair a useful scientific question.

## Next work, in order

1. Implement `single-agent-margin-v1` locally. It reuses the exact Margin
   representation and scorer, and therefore gives the cleanest next answer:
   whether splitting one collaboration task across isolated agents adds value
   versus one continuing agent with matched compute.
2. Prove phase-bound identity, topology-aware cost/trace accounting, all six
   local reference cases, and both served fake-model paths. `marginbench
   controls` is the machine-readable checklist.
3. If those gates pass, propose—but do not automatically run—one public
   calibration cell capped at $0.02. Use the result to repair the environment,
   not to claim a ranking.
4. Define representation-neutral scenario outcomes before building the
   plain-Markdown and no-exchange controls. Do not grade them through
   Margin-specific annotations.
5. Implement Margin-plus-shell only in disposable remote sandboxes. It must
   never run against the host filesystem or inherit benchmark credentials.
6. Add an Environment Hub owner handle when public Prime publication is
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
