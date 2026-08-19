# Public crossover evidence

This directory contains the bounded, independently validatable evidence for
MarginBench's public-development topology and interface calibrations.

- `v15` tests actionable per-file context.
- `v16` tests the first JSON manual and natural audit-kind alias.
- `v17` tests structured progressive manual contracts and exact revision
  semantics.
- `v19` is the first complete paced nine-family real-model topology breadth
  study. It compares fresh role-separated agents with one continuing agent,
  publishes all 18 redacted cells, and records an explicitly
  insufficient-sample descriptive result.

Each version may contain a candidate manifest, settings, crossover plan, capped
Prime execution plan, aggregate report, and redacted per-cell run/summary
artifacts. Older versions predate the resumable controller and therefore do not
necessarily have a Prime execution plan.

Validate any schema-bearing file from the repository root with:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Evals/marginbench \
  python3 -m marginbench.cli validate PATH
```

Audit a whole version as one coherent evidence bundle with:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Evals/marginbench \
  python3 -m marginbench.cli audit-crossover \
  Evals/marginbench/results/crossover/v19
```

The bundle audit validates every published JSON file, checks the candidate and
plan digests, matches each redacted run to its summary, requires both execution
topologies for every episode, and recomputes the aggregate report from the
published cells. It fails closed on missing, extra, symlinked, malformed,
private-setting, or inconsistent artifacts and emits only bounded paths,
digests, counts, and error codes.

These artifacts contain no prompts, document text, raw workspace paths,
contribution identifiers, raw arguments, standard streams, credentials, or
holdout keys. They do retain the synthetic episode and actor identities needed
to audit pairing and attribution. Raw traces, controller state, attempt
receipts, and keys remain under the ignored `runs/` tree and are not publication
inputs. Public development results are mechanism evidence, not leaderboard
claims; every aggregate report records when the sample is too small for a
directional conclusion.
