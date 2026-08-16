# Performance measurement

Margin uses a native AppKit process with no third-party runtime. Release builds and tests use separate SwiftPM scratch paths so Xcode 15.4 (Swift 5.10) artifacts never mix with Command Line Tools 26.4 (Swift 6.x) artifacts.

Run the repeatable local benchmark with:

```sh
make benchmark
```

The default run performs three cache warm-ups and fifteen measured launches of the packaged release app. It records:

- launch latency from spawning `Margin.app/Contents/MacOS/Margin` until its first on-screen layer-0 window is visible;
- resident set size (RSS) 250 ms after that window appears;
- logical app-bundle bytes and main-executable bytes.

Results are written to `build/benchmarks/performance.json`. The launch value is an external window-visible proxy: it is reproducible without modifying production code, but it does not claim to measure the final compositor frame or every asynchronous document-loading operation.

Override the sample size or input when investigating regressions:

```sh
MARGIN_BENCHMARK_RUNS=30 \
MARGIN_BENCHMARK_WARMUPS=5 \
MARGIN_BENCHMARK_DOCUMENT=/path/to/file.md \
make benchmark
```

For clean comparisons, close other Margin instances, use the same hardware and power state, and compare release bundles built with the same macOS toolchain.

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
