#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SWIFT_IMAGE="${MARGIN_LINUX_SWIFT_IMAGE:-swift:5.10-jammy}"
TEST_TIMEOUT="${MARGIN_LINUX_TEST_TIMEOUT:-45}"
XCTEST_TIMEOUT_RETRIES="${MARGIN_LINUX_XCTEST_TIMEOUT_RETRIES:-2}"
BUILD_VOLUME="margin-linux-tests-${$}-${RANDOM}"

case "$(uname -m)" in
    arm64|aarch64) HOST_LINUX_PLATFORM="linux/arm64" ;;
    x86_64|amd64) HOST_LINUX_PLATFORM="linux/amd64" ;;
    *)
        print -u2 "Unsupported host architecture for the Linux test gate: $(uname -m)"
        exit 69
        ;;
esac
LINUX_PLATFORM="${MARGIN_LINUX_PLATFORM:-$HOST_LINUX_PLATFORM}"

cleanup() {
    docker volume rm "$BUILD_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null || {
    print -u2 "Docker is required for the Linux test gate."
    exit 69
}
docker info >/dev/null 2>&1 || {
    print -u2 "Docker is installed but its engine is not running."
    exit 69
}

docker volume create "$BUILD_VOLUME" >/dev/null

run_linux() {
    docker run --platform "$LINUX_PLATFORM" --rm \
        -v "$PROJECT_DIR:/workspace:ro" \
        -v "$BUILD_VOLUME:/build" \
        -w /workspace \
        "$SWIFT_IMAGE" "$@"
}

run_linux_tests() {
    docker run --platform "$LINUX_PLATFORM" --rm \
        --cap-add SYS_PTRACE \
        --network none \
        -v "$PROJECT_DIR:/workspace:ro" \
        -v "$BUILD_VOLUME:/build" \
        -w /workspace \
        "$SWIFT_IMAGE" "$@"
}

# Linux SwiftPM 5.10 can intermittently stall while repeatedly planning an
# already-built test bundle. Build once, then invoke the XCTest binary directly
# in a fresh container/process for each suite. This also catches leaked process
# state and keeps a per-suite timeout explicit.
run_linux swift build --build-tests --scratch-path /build

SUITES=(
    AppLauncherTests
    CLICommandContractTests
    CollaborationChangeSetEvaluatorTests
    CollaborationContextTests
    CollaborationModelsTests
    CollaborationStageRefreshTests
    CollaborationTransactionTests
    CommentAnchorTests
    CommentCodecTests
    CommentMutationTests
    CommentServiceTests
    CommentWatchTests
    ComparisonApplyServiceTests
    ComparisonCommandsTests
    ComparisonDiffTests
    ComparisonReviewTests
    CrossPlatformSupportTests
    MarkdownOutlineTests
    OpenTargetTests
    ReconciliationServiceTests
    ReviewSnapshotTests
    SemanticMergeServiceTests
    TextCoordinatesTests
)

QUALIFIED_SUITES=()
for suite in "${SUITES[@]}"; do
    test_module="MarginCoreTests"
    if [[ "$suite" == AppLauncherTests || "$suite" == CLICommandContractTests \
        || "$suite" == CommentWatchTests || "$suite" == ComparisonCommandsTests ]]; then
        test_module="MarginCLITests"
    fi
    QUALIFIED_SUITES+=("$test_module.$suite")
done

# Swift 5.10 corelibs XCTest wraps even synchronous discovered tests in an
# async teardown task. Its open Linux deadlock can leave that task waiting in
# ppoll before XCTest emits the pass line (swift-corelibs-xctest #504). Run one
# selected test per process. On timeout, the diagnostic runner freezes the
# process and retries only when LLDB proves the exact framework-only teardown
# stack. Product stacks, assertion failures, crashes, ordinary timeouts, and
# debugger failures remain fatal. SYS_PTRACE is confined to this disposable,
# networkless container and cannot observe host processes.
run_linux_tests sh -c '
    set -eu
    per_test_timeout=$1
    timeout_retries=$2
    shift 2
    test_binary=$(find /build -type f -name MarginPackageTests.xctest -print -quit)
    test -n "$test_binary"
    listed_tests=$("$test_binary" --list-tests)
    executed=0
    recovered_timeouts=0
    for qualified_suite do
        echo "Linux suite: ${qualified_suite##*.}"
        matching_tests=$(printf "%s\n" "$listed_tests" | grep -F "$qualified_suite/")
        test -n "$matching_tests"
        for qualified_test in $matching_tests; do
            attempt_log=$(mktemp)
            set +e
            python3 /workspace/Scripts/run-linux-xctest.py \
                --test-binary "$test_binary" \
                --selector "$qualified_test" \
                --timeout "$per_test_timeout" \
                --framework-retries "$timeout_retries" \
                >"$attempt_log" 2>&1
            status=$?
            set -e
            cat "$attempt_log"
            recovered=$(grep -F "MARGIN_XCTEST_FRAMEWORK_TEARDOWN_DEADLOCK_RECOVERED=" "$attempt_log" | tail -1 | cut -d= -f2 || true)
            recovered=${recovered:-0}
            if test "$recovered" -gt 0; then
                recovered_timeouts=$((recovered_timeouts + recovered))
            fi
            /bin/unlink "$attempt_log"
            if test "$status" -ne 0; then
                exit "$status"
            fi
            executed=$((executed + 1))
        done
    done
    echo "Linux XCTest processes passed: $executed (recovered teardown timeouts: $recovered_timeouts)"
' sh "$TEST_TIMEOUT" "$XCTEST_TIMEOUT_RETRIES" "${QUALIFIED_SUITES[@]}"

print "Linux gate passed: ${#SUITES[@]} isolated suites."
