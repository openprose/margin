#!/bin/zsh
set -euo pipefail
export COPYFILE_DISABLE=1

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
SOURCE_APP="$OUTPUT_DIR/Margin.app"
SOURCE_CLI="$OUTPUT_DIR/margin"
INSTALLER_IDENTITY="${MARGIN_INSTALLER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${MARGIN_NOTARY_PROFILE:-}"

if [[ ! -d "$SOURCE_APP" || ! -x "$SOURCE_APP/Contents/MacOS/Margin" ||
      ! -x "$SOURCE_APP/Contents/Helpers/margin" || ! -x "$SOURCE_CLI" ]]; then
    print -u2 "Margin release artifacts are missing. Run make release first."
    exit 66
fi

if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" ]]; then
    print -u2 "Refusing to package from an empty or root output path."
    exit 64
fi

if [[ -n "$NOTARY_PROFILE" &&
      ( -z "$INSTALLER_IDENTITY" || "${MARGIN_APP_SIGNING_IDENTITY:--}" == "-" ) ]]; then
    print -u2 "Notarization requires both Developer ID Application and Installer identities."
    exit 78
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
ARCHES="$(/usr/bin/lipo -archs "$SOURCE_APP/Contents/MacOS/Margin")"
ARCH_LABEL="${ARCHES// /-}"
PACKAGE_NAME="Margin-$VERSION-macOS-$ARCH_LABEL"
PACKAGE_PATH="$OUTPUT_DIR/$PACKAGE_NAME.pkg"
CHECKSUM_PATH="$PACKAGE_PATH.sha256"

if [[ -z "$VERSION" || -z "$BUNDLE_ID" || "${PACKAGE_PATH:t}" != "$PACKAGE_NAME.pkg" ]]; then
    print -u2 "Margin release metadata is incomplete; refusing to build an installer."
    exit 65
fi

[[ "$($SOURCE_CLI --version)" == "Margin $VERSION" ]] || {
    print -u2 "The app and CLI versions do not match."
    exit 65
}
/usr/bin/cmp -s "$SOURCE_CLI" "$SOURCE_APP/Contents/Helpers/margin" || {
    print -u2 "The standalone and bundled CLI executables do not match."
    exit 65
}

STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.margin-installer.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT HUP INT TERM
PAYLOAD_ROOT="$STAGING_ROOT/payload"
TEMP_PACKAGE="$STAGING_ROOT/$PACKAGE_NAME.pkg"

mkdir -p "$PAYLOAD_ROOT/Applications" "$PAYLOAD_ROOT/usr/local/bin"
ditto "$SOURCE_APP" "$PAYLOAD_ROOT/Applications/Margin.app"
install -m 755 "$SOURCE_CLI" "$PAYLOAD_ROOT/usr/local/bin/margin"
/usr/bin/xattr -cr "$PAYLOAD_ROOT"

/usr/bin/plutil -lint "$PAYLOAD_ROOT/Applications/Margin.app/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$PAYLOAD_ROOT/Applications/Margin.app"

PKGBUILD_ARGUMENTS=(
    --root "$PAYLOAD_ROOT"
    --identifier "$BUNDLE_ID.installer"
    --version "$VERSION"
    --install-location /
    --ownership recommended
)
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    PKGBUILD_ARGUMENTS+=(--sign "$INSTALLER_IDENTITY")
fi

/usr/bin/pkgbuild "${PKGBUILD_ARGUMENTS[@]}" "$TEMP_PACKAGE"
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    /usr/sbin/pkgutil --check-signature "$TEMP_PACKAGE" >/dev/null
fi

PAYLOAD_CONTENTS="$(/usr/sbin/pkgutil --payload-files "$TEMP_PACKAGE")"
[[ "$PAYLOAD_CONTENTS" == *"Applications/Margin.app/Contents/MacOS/Margin"* ]] || {
    print -u2 "The installer does not contain Margin.app."
    exit 65
}
[[ "$PAYLOAD_CONTENTS" == *"usr/local/bin/margin"* ]] || {
    print -u2 "The installer does not contain the Margin CLI."
    exit 65
}

rm -f "$PACKAGE_PATH" "$CHECKSUM_PATH"
mv "$TEMP_PACKAGE" "$PACKAGE_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$PACKAGE_PATH" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$PACKAGE_PATH"
    /usr/bin/xcrun stapler validate "$PACKAGE_PATH"
fi
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "${PACKAGE_PATH:t}" > "${CHECKSUM_PATH:t}"
)

print "Packaged installer $PACKAGE_PATH"
if [[ -n "$INSTALLER_IDENTITY" ]]; then
    print "Installer signature $INSTALLER_IDENTITY"
else
    print "Installer is unsigned; set MARGIN_INSTALLER_SIGNING_IDENTITY for public distribution."
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
    print "Installer notarized and stapled with keychain profile $NOTARY_PROFILE"
fi
print "Installs /Applications/Margin.app and /usr/local/bin/margin"
print "Checksum $CHECKSUM_PATH"
