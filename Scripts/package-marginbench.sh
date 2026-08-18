#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PACKAGE_DIR="$PROJECT_DIR/Evals/marginbench"
BINARY_DIR="$PACKAGE_DIR/marginbench/bin"
MANIFEST="$PACKAGE_DIR/BINARY_MANIFEST.json"
OUTPUT_DIR="${MARGINBENCH_DIST_DIR:-$PROJECT_DIR/build/marginbench-package}"
STAGING_DIR="$(mktemp -d /tmp/marginbench-package.XXXXXX)"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT INT TERM

command -v uv >/dev/null || {
    print -u2 "uv is required to package MarginBench."
    exit 69
}
command -v docker >/dev/null || {
    print -u2 "Docker is required to verify the hosted Linux package."
    exit 69
}
command -v jq >/dev/null || {
    print -u2 "jq is required to verify the release manifest."
    exit 69
}
command -v unzip >/dev/null || {
    print -u2 "unzip is required to inspect the wheel metadata."
    exit 69
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        print -u2 "Digest mismatch for $file: expected $expected, found $actual"
        exit 65
    }
}

file_size() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

for architecture in x86_64 aarch64; do
    binary="$BINARY_DIR/margin-linux-$architecture"
    [[ -f "$binary" ]] || {
        print -u2 "Build both Linux artifacts first with: make marginbench-linux-binary"
        exit 66
    }
    expected_sha="$(jq -er --arg architecture "$architecture" '.artifacts[] | select(.architecture == $architecture) | .sha256' "$MANIFEST")"
    expected_bytes="$(jq -er --arg architecture "$architecture" '.artifacts[] | select(.architecture == $architecture) | .bytes' "$MANIFEST")"
    verify_sha256 "$binary" "$expected_sha"
    [[ "$(file_size "$binary")" == "$expected_bytes" ]] || {
        print -u2 "Byte-size mismatch for $binary"
        exit 65
    }
done

source_sha="$({
    find "$PROJECT_DIR/Sources/MarginCore" "$PROJECT_DIR/Sources/MarginCLI" -type f -name '*.swift' -print \
        | LC_ALL=C sort \
        | while IFS= read -r file; do
            relative="${file#$PROJECT_DIR/}"
            printf '%s\0' "$relative"
            shasum -a 256 "$file" | awk '{print $1}'
        done
} | shasum -a 256 | awk '{print $1}')"
[[ "$source_sha" == "$(jq -er '.build.sourceTreeSha256' "$MANIFEST")" ]] || {
    print -u2 "The Linux artifacts were built from an older Margin source tree. Rebuild and refresh BINARY_MANIFEST.json."
    exit 65
}

verify_sha256 "$PACKAGE_DIR/docker/Dockerfile.margin" "$(jq -er '.build.dockerfileSha256' "$MANIFEST")"
verify_sha256 "$PROJECT_DIR/Scripts/build-marginbench-linux.sh" "$(jq -er '.build.scriptSha256' "$MANIFEST")"
verify_sha256 "$PROJECT_DIR/Package.swift" "$(jq -er '.build.packageManifestSha256' "$MANIFEST")"

uv build "$PACKAGE_DIR" --out-dir "$STAGING_DIR/dist"
wheel="$(find "$STAGING_DIR/dist" -type f -name '*.whl' -print -quit)"
source_archive="$(find "$STAGING_DIR/dist" -type f -name '*.tar.gz' -print -quit)"
[[ -n "$wheel" && -n "$source_archive" ]]
[[ "${wheel:t}" == *-py3-none-manylinux_2_35_x86_64.whl ]] || {
    print -u2 "The wheel does not declare its embedded x86-64 Linux binary."
    exit 65
}
wheel_metadata="$(unzip -p "$wheel" '*/WHEEL')"
[[ "$wheel_metadata" == *$'Root-Is-Purelib: false'* && \
   "$wheel_metadata" == *$'Tag: py3-none-manylinux_2_35_x86_64'* ]] || {
    print -u2 "The wheel metadata does not match its embedded Linux executable."
    exit 65
}

mkdir -p "$STAGING_DIR/site"
unzip -q "$wheel" -d "$STAGING_DIR/site"
docker run --platform linux/amd64 --rm \
    -v "$STAGING_DIR/site:/package:ro" \
    -e PYTHONPATH=/package \
    swift:5.10-jammy \
    python3 -m marginbench.cli self-test

mkdir -p "$STAGING_DIR/source"
/usr/bin/tar -xzf "$source_archive" -C "$STAGING_DIR/source"
source_directory="$(find "$STAGING_DIR/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$source_directory" ]]
docker run --platform linux/amd64 --rm \
    -v "$source_directory:/source:ro" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -e PYTHONPATH=/source \
    swift:5.10-jammy \
    python3 -m unittest discover -s /source/tests -p 'test_*.py'

mkdir -p "$OUTPUT_DIR"
# A release directory is a complete snapshot, not an append-only cache. Remove
# only prior MarginBench package artifacts so an obsolete pure-Python wheel can
# never sit beside the platform-tagged wheel and be shipped accidentally.
find "$OUTPUT_DIR" -maxdepth 1 -type f \
    \( -name 'marginbench-*.whl' -o -name 'marginbench-*.tar.gz' \) -delete
install -m 0644 "$wheel" "$OUTPUT_DIR/${wheel:t}"
install -m 0644 "$source_archive" "$OUTPUT_DIR/${source_archive:t}"
shasum -a 256 "$OUTPUT_DIR/${wheel:t}" "$OUTPUT_DIR/${source_archive:t}"
print "Packaged and Linux-verified MarginBench in $OUTPUT_DIR"
