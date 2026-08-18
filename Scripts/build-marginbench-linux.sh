#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DOCKERFILE="$PROJECT_DIR/Evals/marginbench/docker/Dockerfile.margin"
OUTPUT_ROOT="$PROJECT_DIR/build/marginbench-linux"
PACKAGE_BIN="$PROJECT_DIR/Evals/marginbench/marginbench/bin"
ARCHITECTURES=("${@:-amd64}")

command -v docker >/dev/null || {
    print -u2 "Docker is required to build the standalone Linux CLI."
    exit 69
}
docker info >/dev/null 2>&1 || {
    print -u2 "Docker is installed but its engine is not running."
    exit 69
}

mkdir -p "$OUTPUT_ROOT" "$PACKAGE_BIN"

for architecture in "${ARCHITECTURES[@]}"; do
    case "$architecture" in
        amd64) machine="x86_64" ;;
        arm64) machine="aarch64" ;;
        *)
            print -u2 "Unsupported Linux architecture: $architecture"
            exit 64
            ;;
    esac
    destination="$OUTPUT_ROOT/$architecture"
    mkdir -p "$destination"
    docker buildx build \
        --platform "linux/$architecture" \
        --file "$DOCKERFILE" \
        --output "type=local,dest=$destination" \
        "$PROJECT_DIR"
    install -m 0755 "$destination/margin" "$PACKAGE_BIN/margin-linux-$machine"
    file "$PACKAGE_BIN/margin-linux-$machine"
    shasum -a 256 "$PACKAGE_BIN/margin-linux-$machine"
done
