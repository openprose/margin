#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SCRATCH_PATH="${MARGIN_SWIFT_SCRATCH_PATH:-$PROJECT_DIR/.build/toolchains/command-line-tools}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 "usage: $0 [debug|release]"
    exit 64
fi

if [[ -z "$SCRATCH_PATH" || "$SCRATCH_PATH" == "/" || -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" ]]; then
    print -u2 "Refusing to build with an empty or root scratch/output path."
    exit 64
fi

cd "$PROJECT_DIR"
mkdir -p "$SCRATCH_PATH" "$OUTPUT_DIR"

# Swift 5.10 (Xcode) and Swift 6.x (Command Line Tools) cannot safely share
# module/build records. Every invocation is pinned to one toolchain-specific
# scratch directory supplied by the Makefile.
swift build --scratch-path "$SCRATCH_PATH" --configuration "$CONFIGURATION" --product MarginAppBinary
swift build --scratch-path "$SCRATCH_PATH" --configuration "$CONFIGURATION" --product margin-cli
BIN_DIR="$(swift build --scratch-path "$SCRATCH_PATH" --configuration "$CONFIGURATION" --show-bin-path)"

APP_BINARY="$BIN_DIR/MarginAppBinary"
CLI_BINARY="$BIN_DIR/margin-cli"
APP_DIR="$OUTPUT_DIR/Margin.app"
OUTPUT_CLI="$OUTPUT_DIR/margin"

if [[ ! -x "$APP_BINARY" || ! -x "$CLI_BINARY" ]]; then
    print -u2 "SwiftPM did not produce the expected Margin executables in $BIN_DIR."
    exit 70
fi

if [[ "${APP_DIR:t}" != "Margin.app" || "${OUTPUT_CLI:t}" != "margin" ]]; then
    print -u2 "Unexpected package output paths; refusing to replace them."
    exit 64
fi

STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.margin-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT HUP INT TERM
STAGED_APP="$STAGING_ROOT/Margin.app"
STAGED_CLI="$STAGING_ROOT/margin"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Helpers"
install -m 755 "$APP_BINARY" "$STAGED_APP/Contents/MacOS/Margin"
install -m 755 "$CLI_BINARY" "$STAGED_APP/Contents/Helpers/margin"
install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
install -m 755 "$CLI_BINARY" "$STAGED_CLI"

MARGIN_ICON_TOOL_DIR="$SCRATCH_PATH/icon-tool" \
    "$PROJECT_DIR/Scripts/generate-app-icon.sh" \
    "$STAGING_ROOT/AppIcon.iconset" \
    "$STAGED_APP/Contents/Resources/Margin.icns"

if [[ "$CONFIGURATION" == "release" ]]; then
    /usr/bin/strip -x "$STAGED_APP/Contents/MacOS/Margin" "$STAGED_APP/Contents/Helpers/margin" "$STAGED_CLI"
fi

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/Helpers/margin" >/dev/null
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/Margin" >/dev/null
/usr/bin/codesign --force --sign - "$STAGED_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

rm -rf "$APP_DIR"
rm -f "$OUTPUT_CLI"
mv "$STAGED_APP" "$APP_DIR"
mv "$STAGED_CLI" "$OUTPUT_CLI"

print "Built $APP_DIR"
print "Built $OUTPUT_CLI"
print "Swift scratch: $SCRATCH_PATH"
