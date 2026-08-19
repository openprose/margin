#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
SOURCE_APP="$OUTPUT_DIR/Margin.app"
SOURCE_CLI="$OUTPUT_DIR/margin"

if [[ ! -d "$SOURCE_APP" || ! -x "$SOURCE_APP/Contents/MacOS/Margin" || ! -x "$SOURCE_CLI" ]]; then
    print -u2 "Margin release artifacts are missing. Run make release first."
    exit 66
fi

if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" ]]; then
    print -u2 "Refusing to package from an empty or root output path."
    exit 64
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
ARCHES="$(/usr/bin/lipo -archs "$SOURCE_APP/Contents/MacOS/Margin")"
ARCH_LABEL="${ARCHES// /-}"
ARCHIVE_NAME="Margin-$VERSION-macOS-$ARCH_LABEL"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.margin-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT HUP INT TERM
PACKAGE_ROOT="$STAGING_ROOT/$ARCHIVE_NAME"
TEMP_ARCHIVE="$STAGING_ROOT/$ARCHIVE_NAME.zip"

mkdir -p "$PACKAGE_ROOT"
ditto "$SOURCE_APP" "$PACKAGE_ROOT/Margin.app"
install -m 755 "$SOURCE_CLI" "$PACKAGE_ROOT/margin"
install -m 644 "$PROJECT_DIR/Resources/Distribution-README.txt" "$PACKAGE_ROOT/README.txt"
install -m 644 "$PROJECT_DIR/LICENSE" "$PACKAGE_ROOT/LICENSE"
install -m 644 "$PROJECT_DIR/NOTICE" "$PACKAGE_ROOT/NOTICE"

/usr/bin/codesign --verify --deep --strict "$PACKAGE_ROOT/Margin.app"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT" "$TEMP_ARCHIVE"
/usr/bin/unzip -tq "$TEMP_ARCHIVE" >/dev/null

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
mv "$TEMP_ARCHIVE" "$ARCHIVE_PATH"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "${ARCHIVE_PATH:t}" > "${CHECKSUM_PATH:t}"
)

print "Packaged $ARCHIVE_PATH"
print "Checksum $CHECKSUM_PATH"
