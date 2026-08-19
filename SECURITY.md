# Security policy

## Supported versions

Security fixes are made against the latest released version of Margin. Until
the first public release, `main` is the only supported source state.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability or include
private document contents, credentials, holdout keys, or raw model traces in an
issue.

Use GitHub's private vulnerability reporting for this repository. Include:

- The affected version or commit.
- The operating system and architecture.
- Reproduction steps or a minimal proof of concept.
- The impact you believe is possible.
- Whether the report concerns the Mac app, CLI, embedded protocol, or optional
  MarginBench tooling.

We will acknowledge the report, investigate it, and coordinate disclosure based
on its severity and scope. Please allow time for a fix and release before public
disclosure.

## Security boundaries

Margin does not provide a sandbox for Markdown content or for programs that
invoke its CLI. The CLI intentionally reads and writes paths authorized by its
caller. MarginBench has additional isolation and spend-control machinery, but
those controls do not turn arbitrary model or provider output into trusted
input.

The first public macOS release is not Developer ID signed or notarized. Verify
release checksums and follow the bounded first-open instructions in
[`Docs/INSTALLATION.md`](Docs/INSTALLATION.md). Never disable Gatekeeper
globally to install Margin.
