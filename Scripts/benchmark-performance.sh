#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
APP_BUNDLE="${MARGIN_BENCHMARK_APP:-$OUTPUT_DIR/Margin.app}"
DOCUMENT="${MARGIN_BENCHMARK_DOCUMENT:-$PROJECT_DIR/Fixtures/example.md}"
RUNS="${MARGIN_BENCHMARK_RUNS:-15}"
WARMUPS="${MARGIN_BENCHMARK_WARMUPS:-3}"
SETTLE_MS="${MARGIN_BENCHMARK_SETTLE_MS:-250}"
TIMEOUT_MS="${MARGIN_BENCHMARK_TIMEOUT_MS:-5000}"
SCRATCH_PATH="${MARGIN_PERFORMANCE_SCRATCH_PATH:-$PROJECT_DIR/.build/performance}"
RESULTS_PATH="${MARGIN_BENCHMARK_RESULTS:-$OUTPUT_DIR/benchmarks/performance.json}"

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/Margin" || ! -f "$DOCUMENT" ]]; then
    print -u2 "Margin.app or benchmark document is missing. Run make release first."
    exit 66
fi

if [[ -z "$SCRATCH_PATH" || "$SCRATCH_PATH" == "/" || -z "$RESULTS_PATH" ]]; then
    print -u2 "Refusing to benchmark with an empty or root scratch/results path."
    exit 64
fi

mkdir -p "$SCRATCH_PATH" "${RESULTS_PATH:h}"
RUNNER="$SCRATCH_PATH/launch-benchmark"
xcrun swiftc -O "$PROJECT_DIR/Benchmarks/performance/LaunchBenchmark.swift" -o "$RUNNER"

"$RUNNER" \
    --app "$APP_BUNDLE" \
    --document "$DOCUMENT" \
    --runs "$RUNS" \
    --warmups "$WARMUPS" \
    --settle-ms "$SETTLE_MS" \
    --timeout-ms "$TIMEOUT_MS" \
    --output "$RESULTS_PATH"

print "Results: $RESULTS_PATH"
print "Allocated bundle size (KiB): $(/usr/bin/du -sk "$APP_BUNDLE" | /usr/bin/awk '{print $1}')"
