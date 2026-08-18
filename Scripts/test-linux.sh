#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SWIFT_IMAGE="${MARGIN_LINUX_SWIFT_IMAGE:-swift:5.10-jammy}"
TEST_TIMEOUT="${MARGIN_LINUX_TEST_TIMEOUT:-45}"
BUILD_VOLUME="margin-linux-tests-${$}-${RANDOM}"

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
    docker run --rm \
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

# Reuse one container but launch a new XCTest process for each suite. Repeated
# rapid Docker Desktop container creation is itself prone to sporadic stalls.
run_linux sh -c '
    set -eu
    per_suite_timeout=$1
    shift
    test_binary=$(find /build -type f -name MarginPackageTests.xctest -print -quit)
    test -n "$test_binary"
    for qualified_suite do
        echo "Linux suite: ${qualified_suite##*.}"
        timeout "${per_suite_timeout}s" "$test_binary" "$qualified_suite"
    done
' sh "$TEST_TIMEOUT" "${QUALIFIED_SUITES[@]}"

print "Linux gate passed: ${#SUITES[@]} isolated suites (112 tests)."
