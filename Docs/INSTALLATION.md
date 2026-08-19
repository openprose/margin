# Installing Margin

Margin is distributed as a native macOS app with its command-line companion,
and as a standalone command-line tool for Linux. The Linux CLI does not require
the Mac app.

## Choose a download

The `v0.4.0` GitHub release provides these platform packages:

| Platform | Package | Contents |
| --- | --- | --- |
| Apple-silicon Mac, recommended | `Margin-0.4.0-macOS-arm64.pkg` | `Margin.app` and `margin`, installed together |
| Apple-silicon Mac, portable | `Margin-0.4.0-macOS-arm64.zip` | `Margin.app`, a standalone `margin`, and release instructions |
| Linux x86-64 | `Margin-CLI-0.4.0-linux-x86_64.tar.gz` | Standalone `margin` CLI, README, and license |
| Linux ARM64 | `Margin-CLI-0.4.0-linux-aarch64.tar.gz` | Standalone `margin` CLI, README, and license |

Verify the downloaded file against the release's SHA-256 checksum before
opening or installing it.

## macOS installer

The `.pkg` is the simplest installation. It places:

```text
/Applications/Margin.app
/usr/local/bin/margin
```

The application bundle also contains an identical helper at
`/Applications/Margin.app/Contents/Helpers/margin`. The separate copy in
`/usr/local/bin` makes the command available in a normal terminal without
requiring users to reach inside the app bundle.

Open the package and follow the installer. Then verify the CLI:

```sh
margin --version
margin README.md
```

`/usr/local/bin` is already on the default `PATH` in common macOS shells. If
your shell does not find `margin`, add `/usr/local/bin` to `PATH`.

## macOS portable ZIP

Expanding the ZIP produces one versioned directory:

```text
Margin-0.4.0-macOS-arm64/
├── Margin.app
├── margin
└── README.txt
```

Move `Margin.app` to `/Applications` or `~/Applications`. To install the CLI
for one user:

```sh
mkdir -p "$HOME/.local/bin"
install -m 0755 margin "$HOME/.local/bin/margin"
```

Ensure `$HOME/.local/bin` is on `PATH`. An administrator may instead install
the CLI at `/usr/local/bin/margin`.

The CLI finds the app in `~/Applications` or `/Applications`. If the app lives
elsewhere, set `MARGIN_APP_PATH` to its full bundle path.

## Gatekeeper status for v0.4.0

The first public release is not signed with an Apple Developer ID and is not
notarized. Its app executables are ad-hoc signed for bundle integrity, while
the installer package itself is unsigned. macOS will therefore warn or block
the first launch even when the download is intact.

After verifying the release checksum, try opening the package or app normally.
If macOS blocks it:

1. Open **System Settings → Privacy & Security**.
2. Find the message about the blocked Margin package or app.
3. Click **Open Anyway**, authenticate if asked, and confirm the one-time
   exception.

Depending on the macOS version, Control-clicking `Margin.app`, choosing
**Open**, and confirming may present the same per-app exception. Do not disable
Gatekeeper globally.

A future release will use Developer ID Application and Installer certificates,
the hardened runtime, notarization, and stapling. The release workflow is
designed to add those credentials later, but no current release should be
described as Developer ID signed or notarized until its release notes say so.

## Linux CLI

The Linux archives contain the complete file and collaboration CLI. They do
not contain, install, or require `Margin.app`.

Choose the archive for your machine:

```sh
uname -m
```

Use `Margin-CLI-0.4.0-linux-x86_64.tar.gz` for `x86_64` and
`Margin-CLI-0.4.0-linux-aarch64.tar.gz` for `aarch64` or `arm64`. Each expands
to a matching `Margin-CLI-0.4.0-linux-ARCH/` directory. Enter that directory,
then install for the current user:

```sh
mkdir -p "$HOME/.local/bin"
install -m 0755 margin "$HOME/.local/bin/margin"
margin --version
```

If `$HOME/.local/bin` is not on `PATH`, add it in the appropriate shell
configuration. For a machine-wide installation, an administrator may copy the
executable to `/usr/local/bin/margin` instead.

Linux supports document inspection, bounded reads, reviews, comments,
suggestions, handoffs, workspaces, stages, reconciliation, and merges. Commands
whose purpose is to launch the graphical application—bare `margin`, path-first
`margin FILE`, and `margin open`—are macOS-only and return `APP_UNAVAILABLE` on
Linux. See the [CLI guide](CLI.md) for Linux-valid examples.

The release binaries are built with Swift 5.10 on Ubuntu 22.04, include the
Swift standard library statically, and require glibc 2.35 or newer.

## Build and install from source

The macOS application requires macOS 13 or newer and Swift 5.10 or newer. From
the repository root:

```sh
make test
make install
```

The source installer defaults to:

```text
~/Applications/Margin.app
~/.local/bin/margin
```

Override those destinations with `MARGIN_APPLICATIONS_DIR` and
`MARGIN_BIN_DIR`. Use `make release` to build without installing, or
`make package` to create the portable ZIP and unified installer locally.

On Linux, SwiftPM builds only `MarginCore`, the CLI, and their tests; the AppKit
target is excluded. A direct release build produces an executable named
`margin-cli`:

```sh
swift build --configuration release --product margin-cli
swift test
```

For the pinned, static-stdlib archives used in releases, install Docker with
Buildx and run:

```sh
make package-linux
```

This builds both architectures through the repository's pinned Linux container
and writes the archives and checksums below `build/`.
