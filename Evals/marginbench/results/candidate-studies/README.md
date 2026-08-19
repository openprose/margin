# Candidate studies

This directory contains bounded, redacted public-development evidence for
specific Margin interface changes. A study may guide the next iteration, but it
cannot promote a candidate unless it reaches the benchmark's predeclared sample
and safety thresholds.

Each study keeps its frozen candidate descriptions, plans, redacted run
manifests, paired comparison, diagnostic report, submission manifest, and
verification receipt. It does not contain prompts, document text, raw model
traces, credentials, or private holdout material.

From the repository root, verify every tracked study together with the
crossover publications:

```sh
make marginbench-audit
```
