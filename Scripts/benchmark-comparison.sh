#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
APP_BUNDLE="${MARGIN_COMPARISON_BENCHMARK_APP:-$OUTPUT_DIR/Margin.app}"
CLI="${MARGIN_COMPARISON_BENCHMARK_CLI:-$OUTPUT_DIR/margin}"
RUNS="${MARGIN_COMPARISON_BENCHMARK_RUNS:-15}"
WARMUPS="${MARGIN_COMPARISON_BENCHMARK_WARMUPS:-3}"
SETTLE_MS="${MARGIN_COMPARISON_BENCHMARK_SETTLE_MS:-250}"
TIMEOUT_MS="${MARGIN_COMPARISON_BENCHMARK_TIMEOUT_MS:-5000}"
SCRATCH_PATH="${MARGIN_PERFORMANCE_SCRATCH_PATH:-$PROJECT_DIR/.build/performance}"
RESULTS_PATH="${MARGIN_COMPARISON_BENCHMARK_RESULTS:-$OUTPUT_DIR/benchmarks/comparison-performance.json}"
VISIBLE_P95_LIMIT_MS="${MARGIN_COMPARISON_VISIBLE_P95_LIMIT_MS:-}"
COMPLETE_P95_LIMIT_MS="${MARGIN_COMPARISON_COMPLETE_P95_LIMIT_MS:-}"

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/Margin" || ! -x "$CLI" ]]; then
    print -u2 "Margin.app or the Margin CLI is missing. Run make release first."
    exit 66
fi

if [[ -z "$SCRATCH_PATH" || "$SCRATCH_PATH" == "/" || -z "$RESULTS_PATH" ]]; then
    print -u2 "Refusing to benchmark with an empty or root scratch/results path."
    exit 64
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/margin-comparison-benchmark.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
LEFT="$WORK_DIR/reference.md"
RIGHT="$WORK_DIR/proposal.md"
REVIEW="$WORK_DIR/performance.marginreview"

/usr/bin/awk 'BEGIN {
    for (i = 1; i <= 20000; i++) {
        printf "- architecture note %05d: explicit state, bounded work, quiet review.\n", i
    }
}' > "$LEFT"
/usr/bin/awk 'BEGIN {
    for (i = 1; i <= 20000; i++) {
        if (i == 6) {
            printf "- architecture note %05d: explicit state, verified apply, quiet review.\n", i
        } else {
            printf "- architecture note %05d: explicit state, bounded work, quiet review.\n", i
        }
    }
}' > "$RIGHT"

"$CLI" compare "$LEFT" "$RIGHT" \
    --label-left "Reference" \
    --label-right "Proposal" \
    --save-review "$REVIEW" \
    --json >/dev/null

mkdir -p "$SCRATCH_PATH" "${RESULTS_PATH:h}"
RUNNER="$SCRATCH_PATH/comparison-benchmark"
xcrun swiftc -O "$PROJECT_DIR/Benchmarks/performance/ComparisonBenchmark.swift" -o "$RUNNER"

ARGS=(
    --app "$APP_BUNDLE"
    --review "$REVIEW"
    --runs "$RUNS"
    --warmups "$WARMUPS"
    --settle-ms "$SETTLE_MS"
    --timeout-ms "$TIMEOUT_MS"
    --output "$RESULTS_PATH"
)
[[ -n "$VISIBLE_P95_LIMIT_MS" ]] && ARGS+=(--visible-p95-limit-ms "$VISIBLE_P95_LIMIT_MS")
[[ -n "$COMPLETE_P95_LIMIT_MS" ]] && ARGS+=(--complete-p95-limit-ms "$COMPLETE_P95_LIMIT_MS")

"$RUNNER" "${ARGS[@]}"
print "Results: $RESULTS_PATH"
