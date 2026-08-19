# Performance measurement

Margin uses a native AppKit process with no third-party runtime. Release builds and tests use separate SwiftPM scratch paths so Xcode 15.4 (Swift 5.10) artifacts never mix with Command Line Tools 26.4 (Swift 6.x) artifacts.

Run the repeatable local benchmark with:

```sh
make benchmark
```

The default run performs three cache warm-ups and fifteen measured launches of the packaged release app. It records:

- launch latency from spawning `Margin.app/Contents/MacOS/Margin` until its first on-screen layer-0 window is visible;
- target-ready latency until the requested Markdown has been decoded, installed in the real editor with its initial syntax presentation, and made editable when permissions allow;
- resident set size (RSS) 250 ms after that window appears;
- logical app-bundle bytes and main-executable bytes.

Results are written to `build/benchmarks/performance.json`. The visible-window value is an external proxy and does not claim to measure the final compositor frame. The target-ready value comes from an environment-gated marker emitted after initial document presentation and editor activation; ordinary app launches do not create the marker or perform benchmark I/O.

Run the release-sized file and directory matrix with:

```sh
make benchmark-matrix
```

That command covers 4 KiB, 1 MiB, and 5 MiB Markdown files plus directories with 100 and 10,000 entries. A directory result includes root enumeration, initial `README.md` selection, document decoding, and initial Markdown presentation. The checked-in local p95 limits are 500 ms for the first visible window and 1,250 ms for target readiness.

Override the sample size or input when investigating regressions:

```sh
MARGIN_BENCHMARK_RUNS=30 \
MARGIN_BENCHMARK_WARMUPS=5 \
MARGIN_BENCHMARK_DOCUMENT=/path/to/file.md \
make benchmark
```

For clean comparisons, close other Margin instances, use the same hardware and power state, and compare release bundles built with the same macOS toolchain.

## What GitHub Actions can establish

The `Startup performance` workflow runs the complete matrix on one `macos-15` runner, publishes the table in the job summary, retains the raw JSON samples for 90 days, and fails when any case exceeds a 1,000 ms visible-window p95 or 3,000 ms target-ready p95. Keeping all cases in one job makes size comparisons share the same host and machine state.

Those intentionally loose hosted-runner limits are regression alarms, not end-user guarantees. GitHub currently documents the standard public `macos-15` runner as an arm64 M1 VM with three CPUs and 7 GB RAM, but hosted runner load, virtualization, image revisions, thermal state, storage caches, and end-user hardware are outside Margin's control. A hardware-specific service-level guarantee would require a controlled physical or dedicated self-hosted Mac, a pinned OS and toolchain, repeated cold and warm samples, and ongoing calibration. See GitHub's [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [self-hosted runner guidance](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners).

Margin therefore does **not** promise universal sub-200 ms startup. The current AppKit baseline and Margin measurements do not support that claim. The public statement is narrower: the release is continuously checked against the documented CI envelope, and the reference-machine measurements below are reproducible evidence for a specific system.

## Current reference and framework floor

The following reference run used an Apple M1 Max on macOS 26.2, the release bundle, three warm-ups, fifteen measured launches, and the same external window-visible/RSS probe for every row.

| Variant | Launch median | Launch p95 | RSS median | RSS p95 |
|---|---:|---:|---:|---:|
| Minimal AppKit window | 205.745 ms | 233.112 ms | 80.703 MiB | 81.188 MiB |
| Margin with placeholder panes | 298.479 ms | 309.297 ms | 101.844 MiB | 102.047 MiB |
| Margin, no document | 339.943 ms | 347.976 ms | 105.125 MiB | 105.641 MiB |
| Margin, small Markdown file | 331.798 ms | 365.964 ms | 111.625 MiB | 112.438 MiB |
| Margin, project directory | 342.360 ms | 426.197 ms | 112.594 MiB | 112.922 MiB |

The minimal baseline is a 74 KB executable that does nothing beyond starting AppKit and showing an empty window. It establishes that, under this particular external probe and OS release, 150 ms launch and 60 MiB RSS are below the observed AppKit floor rather than useful v0.1 regression gates.

File and empty launches have effectively the same latency distribution, which confirms that Markdown decoding is already off the pre-window path. Replacing the real editor and comment inspector with placeholders saves about 33 ms at the median, but that variant is not ready to edit. Showing placeholders and swapping panes after the probe sees a window would only delay actual readiness, so Margin deliberately does not use that optimization. The ignored scratch baselines are diagnostic only and are not shipped.

## Final v0.1 release gate

After the last UI validation fixes, the exact release candidate was measured again with the same three-warm-up/fifteen-run small-file probe. It reached the first visible window in **339.729 ms median** and **347.985 ms p95**; median RSS 250 ms later was **111.188 MiB** (111.719 MiB p95). The app bundle was 1,951,613 logical bytes and its main executable was 987,216 bytes. These are the authoritative shipped-v0.1 figures; the comparison table above records the immediately preceding controlled baseline experiment.

## Final v0.1.1 release gate

The exact signed v0.1.1 build was measured with the same machine, document, three warm-ups, fifteen runs, and 250 ms RSS settle interval. It reached the first visible window in **232.583 ms median** and **248.301 ms p95**; median RSS was **80.391 MiB** (80.531 MiB p95). Relative to the shipped v0.1.0 measurement, that is a **31.5% lower median launch time**, **28.6% lower p95**, and **27.7% lower median RSS**.

The main reduction comes from constructing the reader subsystem only when reader mode is first requested. Quick Open's recursive filename index is also strictly on demand after `⌘P`; it adds no startup traversal. The source editor remains real and interactive in the initial window—no placeholder pane is used. A separate five-run probe sampling RSS one second after the window appeared measured 80.484 MiB median, confirming that the memory change was not a 250 ms sampling artifact.

The navigation and thread-layout additions increased the app bundle to 2,019,197 logical bytes and the main executable to 1,054,800 bytes. The result remains an external warm-launch proxy, not a claim about cold launch after reboot or the final compositor frame.

## Final v0.1.2 release gate

The exact signed v0.1.2 visual release was measured on the same machine and fixture with three warm-ups, fifteen runs, and the 250 ms RSS settle interval. It reached the first visible window in **223.750 ms median** and **232.907 ms p95**; median RSS was **80.734 MiB** (80.938 MiB p95).

That distribution overlaps v0.1.1 and shows no launch regression: the median was 3.8% lower and p95 6.2% lower in this run, while median RSS differed by 0.343 MiB. The adaptive palette, typographic hierarchy, and refined review surfaces are code-native AppKit work; reader construction, recursive filename discovery, and document decoding remain outside the pre-window path. The bundle is 2,053,005 logical bytes and the main executable is 1,088,608 bytes.

## Final v0.1.3 release gate

The exact signed v0.1.3 candidate completed the standard three-warm-up/fifteen-run probe at **292.688 ms median** and **338.877 ms p95**; median RSS was **148.094 MiB** (148.609 MiB p95). The bundle is 2,086,301 logical bytes and the main executable is 1,121,904 bytes.

The earlier v0.1.2 absolute distribution was not reproducible in the current machine session: rerunning the exact installed v0.1.2 binary back-to-back produced 296.394 ms median and 132.391 MiB median RSS across five measured launches. A matching five-run v0.1.3 control produced 286.834 ms median and 147.781 MiB median RSS. The current evidence therefore shows no launch-latency regression. The candidate used roughly 15 MiB more at this sampling point; native tab/window infrastructure and the larger useful default surface are the material presentation changes, but this probe does not isolate their individual shares.

All optional v0.1.3 work remains off the single-document launch path: the comment view stays unloaded until a reviewed document needs it, reader construction begins only on demand, file-provider watcher descriptors open on a utility queue, and native tab groups are created only when a second document appears. The benchmark still measures a real editor window rather than a placeholder.

## Final v0.2.0 release gate

The exact signed v0.2.0 candidate completed an extended five-warm-up/thirty-run probe at **307.327 ms median** and **336.417 ms p95**; median RSS was **158.617 MiB** (159.953 MiB p95). The bundle is 2,807,725 logical bytes and the main executable is 1,545,280 bytes.

To control for macOS framework-residency variation, commit `591b172` (v0.1.3) was rebuilt immediately beside the final candidate with the same toolchain, fixture, warm-ups, run count, and probe. That paired thirty-run baseline measured **315.452 ms median / 382.316 ms p95** with **164.868 MiB median RSS** (166.313 MiB p95). The complete review-loop release therefore improves median launch by **8.125 ms (2.6%)**, p95 by **45.899 ms (12.0%)**, and sampled median RSS by **6.251 MiB (3.8%)**. It retains a real, immediately editable source view and adds no startup or footprint regression under the paired gate.

The added selection affordance, reader markers, comment presentation index, Markdown comment renderer, unread badge, command palette, recursive filename index, and recent-workspace reads are all created only when their interaction requires them. Reader parsing remains off the source launch path. Document decoding is asynchronous; file-watch descriptors, recent writes, and session serialization use utility queues. Explicit CLI targets bypass session loading, and no new dependency, network request, database, daemon, WebView, or placeholder editor was introduced.

## Final v0.3.0 release gate

The exact signed v0.3.0 candidate and the installed v0.2.0 release were measured
back-to-back on the same machine, document, and session with five warm-ups,
thirty measured launches, and the same 250 ms RSS settle interval.

| Exact build | Launch median | Launch p95 | RSS median | RSS p95 |
|---|---:|---:|---:|---:|
| Installed v0.2.0 control | 302.981 ms | 315.554 ms | 159.493 MiB | 162.063 MiB |
| Signed v0.3.0 candidate | 299.551 ms | 316.099 ms | 160.000 MiB | 162.641 MiB |

The candidate median is **3.430 ms (1.1%) faster**; p95 differs by **0.545
ms (0.2%)**, and median RSS by **0.507 MiB (0.3%)**. Those distributions
show no meaningful launch or sampled-memory regression. The real source editor
is visible at the measurement boundary—there is no placeholder window.

## Final v0.3.2 release gate

The exact signed v0.3.2 build completed the standard three-warm-up/fifteen-run
small-file probe at **286.610 ms median** and **289.237 ms p95**; median RSS was
**159.016 MiB**. This overlaps the controlled v0.3.0 distribution and shows no
launch or sampled-memory regression after adding the self-teaching CLI and the
portable benchmark. Benchmark and provider integrations remain entirely
outside the application launch path.

The final v0.3.2 app bundle is 5,732,157 logical bytes and its main executable
is 2,790,704 bytes; the standalone release CLI is 2,609,168 bytes. The larger
artifact contains the shared collaboration, transaction, recovery,
reconciliation, and merge engine, but none of that work executes before the
first window. Directory contexts, actor aggregation, stage loading, semantic
previews, filename indexing, and reader construction remain explicitly
on-demand.

The exact final CLI also completed the strict collaboration preflight. In a
fresh 100-process sample after three warmups, static help measured 5.247 ms
median / 5.832 ms p95 and the full 69,995-byte capability contract measured
7.441 ms median / 8.119 ms p95. Workflow projections are 7.0–18.8 KB and stay
filesystem-free. These CLI timings are separate from the AppKit window-visible
probe above.

### Structured-manual follow-up

The later v0.3.2 structured-manual candidate changed only static CLI teaching
and context metadata; no AppKit launch-path source changed. The standard
three-warm-up/fifteen-run probe measured **320.756 ms median** and **332.541 ms
p95**, with **162.031 MiB median RSS**. This is inside the broad session-to-
session spread documented above and does not isolate a regression; the main app
executable remains 2,807,872 bytes.

Across 100 fresh CLI processes after three warmups, ordinary help measured
**6.044 ms median / 7.367 ms p95**, structured `man comments --json` measured
**6.861 / 8.357 ms**, and `capabilities --json --for comments` measured **7.183
/ 8.477 ms**. The corresponding structured outputs are 12,716 and 19,797
bytes, both below their hard bounds and independent of filesystem or network
state.

## v0.4.0 startup matrix baseline

The v0.4.0 release candidate completed the new matrix on an Apple M1 Max with
macOS 26.2. Every case used three warm-ups and ten measured direct launches.

| Case | Visible median | Visible p95 | Ready median | Ready p95 |
|---|---:|---:|---:|---:|
| 4 KiB Markdown file | 323.903 ms | 403.134 ms | 354.102 ms | 442.868 ms |
| 1 MiB Markdown file | 317.479 ms | 343.534 ms | 470.048 ms | 496.853 ms |
| 5 MiB Markdown file | 319.724 ms | 366.418 ms | 920.244 ms | 983.171 ms |
| Directory with 100 entries | 323.939 ms | 332.526 ms | 513.149 ms | 521.528 ms |
| Directory with 10,000 entries | 320.360 ms | 327.736 ms | 1,030.775 ms | 1,060.048 ms |

The nearly flat visible-window results confirm that file decoding and directory
enumeration do not block the first window. Target readiness scales with the
requested work and remains within the checked-in 1,250 ms local p95 envelope
for this matrix. These warm-launch figures support “a few hundred milliseconds
to a visible window” on the reference system, not a sub-200 ms claim.
