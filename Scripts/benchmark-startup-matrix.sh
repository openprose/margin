#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
RESULTS_DIR="${MARGIN_STARTUP_RESULTS_DIR:-$OUTPUT_DIR/benchmarks/startup-matrix}"
RUNS="${MARGIN_STARTUP_RUNS:-10}"
WARMUPS="${MARGIN_STARTUP_WARMUPS:-3}"
VISIBLE_LIMIT_MS="${MARGIN_STARTUP_VISIBLE_P95_LIMIT_MS:-500}"
READY_LIMIT_MS="${MARGIN_STARTUP_READY_P95_LIMIT_MS:-1250}"
TIMEOUT_MS="${MARGIN_STARTUP_TIMEOUT_MS:-10000}"

FIXTURE_ROOT="$(mktemp -d "${TMPDIR%/}/margin-startup.XXXXXX")"
cleanup() {
    case "$FIXTURE_ROOT" in
        "${TMPDIR%/}"/margin-startup.*) /bin/rm -rf -- "$FIXTURE_ROOT" ;;
    esac
}
trap cleanup EXIT INT TERM

make_text_file() {
    local destination="$1"
    local bytes="$2"
    set +o pipefail
    /usr/bin/yes 'Margin startup benchmark paragraph.' \
        | /usr/bin/head -c "$bytes" > "$destination"
    set -o pipefail
}

make_directory() {
    local destination="$1"
    local entries="$2"
    mkdir -p "$destination"
    cp "$PROJECT_DIR/Fixtures/example.md" "$destination/README.md"
    local index
    for (( index = 2; index <= entries; index++ )); do
        /bin/ln "$destination/README.md" "$destination/entry-$index.txt"
    done
}

mkdir -p "$RESULTS_DIR"
make_text_file "$FIXTURE_ROOT/file-4-kib.md" 4096
make_text_file "$FIXTURE_ROOT/file-1-mib.md" 1048576
make_text_file "$FIXTURE_ROOT/file-5-mib.md" 5242880
make_directory "$FIXTURE_ROOT/directory-100" 100
make_directory "$FIXTURE_ROOT/directory-10000" 10000

SUMMARY_PATH="$RESULTS_DIR/summary.md"
{
    print '## Margin startup performance'
    print
    print "Warm direct launches: $WARMUPS warm-ups and $RUNS measured runs per case."
    print
    print "Limits: visible-window p95 ≤ ${VISIBLE_LIMIT_MS} ms; target-ready p95 ≤ ${READY_LIMIT_MS} ms."
    print
    print '| Case | Visible median | Visible p95 | Ready median | Ready p95 | Result |'
    print '|---|---:|---:|---:|---:|---|'
} > "$SUMMARY_PATH"

overall_status=0
run_case() {
    local label="$1"
    local slug="$2"
    local target="$3"
    local result="$RESULTS_DIR/$slug.json"
    local case_status=0

    MARGIN_BENCHMARK_APP="$OUTPUT_DIR/Margin.app" \
    MARGIN_BENCHMARK_DOCUMENT="$target" \
    MARGIN_BENCHMARK_RUNS="$RUNS" \
    MARGIN_BENCHMARK_WARMUPS="$WARMUPS" \
    MARGIN_BENCHMARK_SETTLE_MS=0 \
    MARGIN_BENCHMARK_TIMEOUT_MS="$TIMEOUT_MS" \
    MARGIN_BENCHMARK_VISIBLE_P95_LIMIT_MS="$VISIBLE_LIMIT_MS" \
    MARGIN_BENCHMARK_READY_P95_LIMIT_MS="$READY_LIMIT_MS" \
    MARGIN_BENCHMARK_RESULTS="$result" \
        "$PROJECT_DIR/Scripts/benchmark-performance.sh" >/dev/null || case_status=$?

    if [[ -f "$result" ]]; then
        local visible_median visible_p95 ready_median ready_p95 outcome
        visible_median="$(/usr/bin/plutil -extract launchMilliseconds.median raw "$result")"
        visible_p95="$(/usr/bin/plutil -extract launchMilliseconds.p95 raw "$result")"
        ready_median="$(/usr/bin/plutil -extract readyMilliseconds.median raw "$result")"
        ready_p95="$(/usr/bin/plutil -extract readyMilliseconds.p95 raw "$result")"
        outcome=$([[ "$case_status" -eq 0 ]] && print 'pass' || print 'fail')
        print "| $label | ${visible_median} ms | ${visible_p95} ms | ${ready_median} ms | ${ready_p95} ms | $outcome |" \
            >> "$SUMMARY_PATH"
    else
        print "| $label | — | — | — | — | fail |" >> "$SUMMARY_PATH"
        case_status=1
    fi

    if [[ "$case_status" -ne 0 ]]; then
        overall_status=1
    fi
}

run_case '4 KiB Markdown file' file-4-kib "$FIXTURE_ROOT/file-4-kib.md"
run_case '1 MiB Markdown file' file-1-mib "$FIXTURE_ROOT/file-1-mib.md"
run_case '5 MiB Markdown file' file-5-mib "$FIXTURE_ROOT/file-5-mib.md"
run_case 'Directory with 100 entries' directory-100 "$FIXTURE_ROOT/directory-100"
run_case 'Directory with 10,000 entries' directory-10000 "$FIXTURE_ROOT/directory-10000"

print >> "$SUMMARY_PATH"
print '“Visible” means the first on-screen layer-0 window. “Ready” means the requested file has been decoded and installed in the real editor, including initial Markdown presentation and editor activation. Directory cases include root enumeration, selection of `README.md`, and that document-ready milestone.' >> "$SUMMARY_PATH"

/bin/cat "$SUMMARY_PATH"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    /bin/cat "$SUMMARY_PATH" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$overall_status"
