#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PLIST="$PROJECT_DIR/Resources/Info.plist"
CLI_SOURCE="$PROJECT_DIR/Sources/MarginCLI/MarginCommand.swift"
DISTRIBUTION_README="$PROJECT_DIR/Resources/Distribution-README.txt"
BINARY_MANIFEST="$PROJECT_DIR/Evals/marginbench/BINARY_MANIFEST.json"
EXPECTED="${1:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
    VERSION="$(python3 - "$PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    print(plistlib.load(source)["CFBundleShortVersionString"])
PY
)"
fi

if ! print -r -- "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    print -u2 "Invalid product version in Resources/Info.plist: $VERSION"
    exit 65
fi

if [[ -n "$EXPECTED" ]]; then
    EXPECTED="${EXPECTED#v}"
    [[ "$EXPECTED" == "$VERSION" ]] || {
        print -u2 "Expected version $EXPECTED, but the product version is $VERSION."
        exit 65
    }
fi

CLI_VERSION="$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)"[[:space:]]*$/\1/p' "$CLI_SOURCE")"
[[ "$CLI_VERSION" == "$VERSION" ]] || {
    print -u2 "CLI version $CLI_VERSION does not match product version $VERSION."
    exit 65
}

README_VERSION="$(sed -n '1s/^Margin //p' "$DISTRIBUTION_README")"
[[ "$README_VERSION" == "$VERSION" ]] || {
    print -u2 "Distribution README version $README_VERSION does not match product version $VERSION."
    exit 65
}

MANIFEST_VERSION="$(python3 - "$BINARY_MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["marginVersion"])
PY
)"
[[ "$MANIFEST_VERSION" == "$VERSION" ]] || {
    print -u2 "MarginBench binary version $MANIFEST_VERSION does not match product version $VERSION."
    exit 65
}

BUILD_NUMBER="$(python3 - "$PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    print(plistlib.load(source)["CFBundleVersion"])
PY
)"
print -r -- "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$' || {
    print -u2 "CFBundleVersion must be a positive integer, found $BUILD_NUMBER."
    exit 65
}

print "Margin version $VERSION (build $BUILD_NUMBER) is consistent."
