#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
SOURCE_APP="$OUTPUT_DIR/Margin.app"
SOURCE_CLI="$OUTPUT_DIR/margin"
USER_HOME="${HOME:?HOME is not set}"
APPLICATIONS_DIR="${MARGIN_APPLICATIONS_DIR:-$USER_HOME/Applications}"
BIN_DIR="${MARGIN_BIN_DIR:-$USER_HOME/.local/bin}"
TARGET_APP="$APPLICATIONS_DIR/Margin.app"
TARGET_CLI="$BIN_DIR/margin"

if [[ ! -d "$SOURCE_APP" || ! -x "$SOURCE_CLI" ]]; then
    print -u2 "Margin has not been built. Run make release first."
    exit 66
fi

if [[ -z "$APPLICATIONS_DIR" || "$APPLICATIONS_DIR" == "/" || -z "$BIN_DIR" || "$BIN_DIR" == "/" ||
      "${TARGET_APP:t}" != "Margin.app" || "${TARGET_CLI:t}" != "margin" ]]; then
    print -u2 "Refusing to install to an empty, root, or unexpected target path."
    exit 64
fi

/usr/bin/plutil -lint "$SOURCE_APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR"

STAGING_ROOT="$(mktemp -d "$APPLICATIONS_DIR/.margin-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Margin.app"
STAGED_CLI="$(mktemp "$BIN_DIR/.margin.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"; rm -f "$STAGED_CLI"' EXIT HUP INT TERM

ditto "$SOURCE_APP" "$STAGED_APP"
install -m 755 "$SOURCE_CLI" "$STAGED_CLI"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

rm -rf "$TARGET_APP"
mv "$STAGED_APP" "$TARGET_APP"
mv -f "$STAGED_CLI" "$TARGET_CLI"

if [[ "${MARGIN_SKIP_LAUNCH_SERVICES:-0}" != "1" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
fi

print "Installed $TARGET_APP"
print "Installed $TARGET_CLI"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    print "Add $BIN_DIR to PATH, then run: margin README.md"
else
    print "Run: margin README.md"
fi
