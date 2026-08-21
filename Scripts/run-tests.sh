#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SCRATCH_PATH="${MARGIN_TEST_SCRATCH_PATH:-$PROJECT_DIR/.build/toolchains/xcode}"
export DEVELOPER_DIR="$("$PROJECT_DIR/Scripts/select-test-toolchain.sh")"

if [[ -z "$SCRATCH_PATH" || "$SCRATCH_PATH" == "/" ]]; then
    print -u2 "Refusing to test with an empty or root scratch path."
    exit 64
fi

cd "$PROJECT_DIR"

# AppKit window and sheet animations can survive beyond an XCTest method's
# autorelease pool when an entire mixed test bundle shares one process. On newer
# macOS releases, the older XCTest runtime selected for the deployment target
# can then crash while disposing an unrelated transform animation. Build once,
# keep the headless core and CLI tests grouped, and give each native UI suite a
# fresh process. This preserves every test while making the release gate
# deterministic across the supported toolchains.
test_list="$(swift test list --scratch-path "$SCRATCH_PATH")"
unclassified="$(
    print -r -- "$test_list" \
        | sed -n '/^[A-Za-z].*\//p' \
        | grep -Ev '^Margin(Core|CLI|App)Tests\.' \
        || true
)"
if [[ -n "$unclassified" ]]; then
    print -u2 "The native test runner found an unclassified test target:"
    print -u2 -r -- "$unclassified"
    exit 65
fi

print "Native suites: MarginCoreTests and MarginCLITests"
swift test \
    --scratch-path "$SCRATCH_PATH" \
    --skip-build \
    --filter '^(MarginCoreTests|MarginCLITests)\.'

app_suites=("${(@f)$(
    print -r -- "$test_list" \
        | sed -n 's/^MarginAppTests\.\([^/]*\)\/.*/\1/p' \
        | LC_ALL=C sort -u
)}")
(( ${#app_suites[@]} > 0 )) || {
    print -u2 "The native test runner discovered no MarginAppTests suites."
    exit 65
}

for suite in "${app_suites[@]}"; do
    print "Native AppKit suite: $suite"
    swift test \
        --scratch-path "$SCRATCH_PATH" \
        --skip-build \
        --filter "^MarginAppTests\\.$suite/"
done
