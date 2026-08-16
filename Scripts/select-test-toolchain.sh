#!/bin/zsh
set -euo pipefail

requested="${MARGIN_TEST_DEVELOPER_DIR:-}"
if [[ -n "$requested" ]]; then
    if [[ -x "$requested/usr/bin/xctest" ]]; then
        print -r -- "$requested"
        exit 0
    fi
    print -u2 "The requested test toolchain has no XCTest runner: $requested"
    exit 69
fi

current="$(xcode-select -p 2>/dev/null || true)"
fallback="/Applications/Xcode-15.4.0.app/Contents/Developer"
candidates=("$current" "$fallback")
for developer in /Applications/Xcode*.app/Contents/Developer(N); do
    candidates+=("$developer")
done

typeset -A seen
for developer in "${candidates[@]}"; do
    [[ -n "$developer" && -z "${seen[$developer]:-}" ]] || continue
    seen[$developer]=1
    if [[ -x "$developer/usr/bin/xctest" ]]; then
        print -r -- "$developer"
        exit 0
    fi
done

print -u2 "No full Xcode installation with XCTest was found."
exit 69
