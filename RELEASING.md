# Releasing Margin

GitHub Releases are the canonical distribution channel. A `vX.Y.Z` tag builds
four installable archives from that exact commit and creates a draft release:

- `Margin-X.Y.Z-macOS-arm64.pkg` installs `Margin.app` in `/Applications` and
  the `margin` CLI in `/usr/local/bin`.
- `Margin-X.Y.Z-macOS-arm64.zip` contains the app, CLI, and a short installation
  guide for a portable installation.
- `Margin-CLI-X.Y.Z-linux-x86_64.tar.gz` contains the standalone Linux CLI.
- `Margin-CLI-X.Y.Z-linux-aarch64.tar.gz` contains the standalone Linux CLI.
- `SHA256SUMS` authenticates the downloaded bytes against the release page.

Every binary distribution carries the repository's Apache-2.0 `LICENSE` and
`NOTICE`; the macOS installer carries them inside the application resources.

The workflow also publishes GitHub build-provenance attestations. Verify an
asset with `gh attestation verify ASSET --repo openprose/margin`, then check the
download set with `sha256sum --check SHA256SUMS`.

## Prepare a version

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
2. Update `MarginCommand.version` in `Sources/MarginCLI/MarginCommand.swift`.
3. Update the first line of `Resources/Distribution-README.txt`.
4. Rebuild the x86-64 and arm64 MarginBench binaries and refresh their bytes,
   digests, source-tree digest, and `marginVersion` in
   `Evals/marginbench/BINARY_MANIFEST.json`. Historical candidate IDs and old
   release evidence must not be rewritten.
5. Add the version's user-facing notes to the release notes and run:

   ```sh
   make check-version
   make test
   make test-linux
   make package
   make package-linux
   ```

The release tag must exactly match the checked product version. Before tagging,
run a secret scan over both the working tree and Git history, inspect the four
archives, and ensure the intended commit is on `main`.

Create and push an annotated tag only after CI is green:

```sh
git tag -a v0.5.0 -m "Margin 0.5.0"
git push origin v0.5.0
```

The tag workflow uses native GitHub-hosted arm64 runners for macOS and Linux
arm64, and an x86-64 runner for Linux x86-64. It runs the relevant tests before
packaging, checks the exact asset set, emits consolidated checksums and
attestations, and creates a **draft** release. Review the draft, its generated
notes, checksums, and installation instructions before publishing it. Never move
or reuse a published version tag; correct a bad release with a new version.

## First-release macOS trust behavior

The current app executables are ad-hoc signed and the installer itself is
unsigned. They are not notarized. Downloaded builds therefore require the user
to explicitly approve Margin in macOS System Settings under Privacy & Security.
Do not tell users to disable Gatekeeper globally or strip quarantine metadata.

The local packaging hooks are already credential-ready:

- `MARGIN_APP_SIGNING_IDENTITY` selects a Developer ID Application identity.
- `MARGIN_INSTALLER_SIGNING_IDENTITY` selects a Developer ID Installer identity.
- `MARGIN_NOTARY_PROFILE` selects a `notarytool` keychain profile and makes the
  installer submission, stapling, and validation part of packaging.

When OpenProse obtains those credentials, store the certificate material and
notary API credentials as GitHub environment secrets, import them into an
ephemeral keychain in the macOS release job, create the temporary notary profile,
and pass the three variables above. Put the signing job behind a protected
`release` environment, delete the keychain after the job, and add `spctl`,
`pkgutil --check-signature`, and stapler validation gates. The artifact names and
the rest of the release workflow do not need to change.
