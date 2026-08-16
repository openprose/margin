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
swift test --scratch-path "$SCRATCH_PATH"
