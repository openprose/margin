#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
APP_BUNDLE="$OUTPUT_DIR/Margin.app"
CLI="$OUTPUT_DIR/margin"
FIXTURE="$PROJECT_DIR/Fixtures/example.md"
SMOKE_RESULTS="$OUTPUT_DIR/benchmarks/smoke.json"

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/Margin" || ! -x "$CLI" ]]; then
    print -u2 "Margin release artifacts are missing. Run make release first."
    exit 66
fi

/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
[[ "$($CLI --version)" == "Margin 0.3.0" ]]
"$CLI" inspect --json "$FIXTURE" >/dev/null
"$CLI" outline --json "$FIXTURE" >/dev/null

MARGIN_BENCHMARK_APP="$APP_BUNDLE" \
MARGIN_BENCHMARK_DOCUMENT="$FIXTURE" \
MARGIN_BENCHMARK_RUNS=1 \
MARGIN_BENCHMARK_WARMUPS=0 \
MARGIN_BENCHMARK_SETTLE_MS=0 \
MARGIN_BENCHMARK_RESULTS="$SMOKE_RESULTS" \
    "$PROJECT_DIR/Scripts/benchmark-performance.sh" >/dev/null

print "Smoke checks passed: bundle, CLI, document inspection, and app window launch."
