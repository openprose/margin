#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
ICONSET_DIR="${1:-}"
ICNS_PATH="${2:-}"
TOOL_DIR="${MARGIN_ICON_TOOL_DIR:-$PROJECT_DIR/.build/icon-tool}"

if [[ -z "$ICONSET_DIR" || -z "$ICNS_PATH" || "${ICONSET_DIR:e}" != "iconset" || "${ICNS_PATH:e}" != "icns" ]]; then
    print -u2 "usage: $0 OUTPUT.iconset OUTPUT.icns"
    exit 64
fi

mkdir -p "$TOOL_DIR"
GENERATOR="$TOOL_DIR/generate-app-icon"
xcrun swiftc -O "$PROJECT_DIR/Scripts/generate-app-icon.swift" -o "$GENERATOR"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR" "${ICNS_PATH:h}"
"$GENERATOR" "$ICONSET_DIR"
/usr/bin/iconutil --convert icns --output "$ICNS_PATH" "$ICONSET_DIR"

if [[ ! -s "$ICNS_PATH" ]]; then
    print -u2 "iconutil did not produce $ICNS_PATH"
    exit 70
fi
