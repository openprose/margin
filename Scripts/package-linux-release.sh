#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${MARGIN_BUILD_OUTPUT_DIR:-$PROJECT_DIR/build}"
if (( $# == 0 )); then
    set -- amd64 arm64
fi
ARCHITECTURES=("$@")

if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" ]]; then
    print -u2 "Refusing to package into an empty or root output path."
    exit 64
fi

VERSION="$(python3 - "$PROJECT_DIR/Resources/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    print(plistlib.load(source)["CFBundleShortVersionString"])
PY
)"
"$PROJECT_DIR/Scripts/check-version.sh" "$VERSION"

for architecture in "${ARCHITECTURES[@]}"; do
    case "$architecture" in
        amd64)
            machine="x86_64"
            verify_image="python@sha256:0f16c5d35fe6464ee471792ab3bb9116f911b65b3fbf10120c98d2bdc6332f48"
            ;;
        arm64)
            machine="aarch64"
            verify_image="python@sha256:3b6bee0531ed64639c7846e5a083a3d13531ceb58326f52d63d436f4edabf50e"
            ;;
        *)
            print -u2 "Unsupported Linux architecture: $architecture"
            exit 64
            ;;
    esac

    "$PROJECT_DIR/Scripts/build-marginbench-linux.sh" "$architecture"
    source_binary="$PROJECT_DIR/build/marginbench-linux/$architecture/margin"
    [[ -x "$source_binary" ]] || {
        print -u2 "The Linux build did not produce $source_binary."
        exit 66
    }
    built_version="$(docker run --rm --platform "linux/$architecture" \
        -v "$source_binary:/margin:ro" \
        "$verify_image" \
        /margin --version)"
    [[ "$built_version" == "Margin $VERSION" ]] || {
        print -u2 "The Linux $machine executable has the wrong version."
        exit 65
    }

    archive_root="Margin-CLI-$VERSION-linux-$machine"
    archive="$OUTPUT_DIR/$archive_root.tar.gz"
    checksum="$archive.sha256"
    staging="$(mktemp -d "$OUTPUT_DIR/.margin-linux-package.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT HUP INT TERM

    mkdir -p "$staging/$archive_root"
    install -m 0755 "$source_binary" "$staging/$archive_root/margin"
    install -m 0644 "$PROJECT_DIR/LICENSE" "$staging/$archive_root/LICENSE"
    install -m 0644 "$PROJECT_DIR/NOTICE" "$staging/$archive_root/NOTICE"
    printf '%s\n' \
        "Margin CLI $VERSION for Linux $machine" \
        "" \
        "Copy margin to a directory on PATH. For a user-only install:" \
        "" \
        "    install -Dm755 margin \"\$HOME/.local/bin/margin\"" \
        "" \
        "The native graphical editor is macOS-only. This archive contains the" \
        "complete headless collaboration CLI and requires glibc 2.35 or newer." \
        > "$staging/$archive_root/README.txt"

    rm -f "$archive" "$checksum"
    COPYFILE_DISABLE=1 tar -C "$staging" -czf "$archive" "$archive_root"
    tar -tzf "$archive" >/dev/null
    (
        cd "$OUTPUT_DIR"
        shasum -a 256 "${archive:t}" > "${checksum:t}"
    )
    rm -rf "$staging"
    trap - EXIT HUP INT TERM

    print "Packaged $archive"
    print "Checksum $checksum"
done
