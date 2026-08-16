#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
targets=(
    "$PROJECT_DIR/.build/toolchains"
    "$PROJECT_DIR/.build/performance"
    "$PROJECT_DIR/.scratch"
    "$PROJECT_DIR/.build-xcode"
    "$PROJECT_DIR/build"
)

for target in "${targets[@]}"; do
    resolved="${target:A}"
    if [[ "$resolved" != "$PROJECT_DIR/"* ]]; then
        print -u2 "Refusing to clean path outside the Margin project: $resolved"
        exit 64
    fi
done

rm -rf "${targets[@]}"
print "Removed Margin build artifacts."
