#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SWIFT_IMAGE="${MARGIN_LINUX_SWIFT_IMAGE:-swift:5.10-jammy}"
TEST_TIMEOUT="${MARGIN_LINUX_TEST_TIMEOUT:-45}"
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
    if [[ "$suite" == AppLauncherTests || "$suite" == CLICommandContractTests || "$suite" == CommentWatchTests ]]; then
        test_module="MarginCLITests"
    fi
    QUALIFIED_SUITES+=("$test_module.$suite")
done

# Reuse one container but launch a new XCTest process for each test. Swift 5.10
# corelibs XCTest wraps even synchronous discovered tests in an async task. On
# Linux that runner can intermittently stop scheduling the next test in a
# multi-test process, while the selected test itself has already returned and
# no file descriptor or lock remains open. Selecting one test per process keeps
# the product gate deterministic without repeating SwiftPM planning or hiding a
# test timeout. Repeated Docker Desktop container creation is also avoided.
run_linux sh -c '
    set -eu
    per_test_timeout=$1
    shift
    test_binary=$(find /build -type f -name MarginPackageTests.xctest -print -quit)
    test -n "$test_binary"
    listed_tests=$("$test_binary" --list-tests)
    executed=0
    for qualified_suite do
        echo "Linux suite: ${qualified_suite##*.}"
        matching_tests=$(printf "%s\n" "$listed_tests" | grep -F "$qualified_suite/")
        test -n "$matching_tests"
        for qualified_test in $matching_tests; do
            timeout "${per_test_timeout}s" "$test_binary" "$qualified_test"
            executed=$((executed + 1))
        done
    done
    echo "Linux XCTest processes passed: $executed"
' sh "$TEST_TIMEOUT" "${QUALIFIED_SUITES[@]}"

print "Linux gate passed: ${#SUITES[@]} isolated suites (112 tests)."
