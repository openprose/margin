# Margin roadmap

Margin is deliberately a focused, file-native Markdown tool. Roadmap items are
directions rather than promises or dates.

## In progress for the next release

- Source-agnostic Markdown comparison and portable review threads in the native
  app and CLI, without repository discovery or Git-owned state.

## Shipped through 0.4.1

- Native file and directory editing, reader mode, tabs, navigation, restoration,
  and inline threaded review on macOS.
- A standalone macOS/Linux CLI for bounded reads, comments, suggestions,
  handoffs, staging, recovery, reconciliation, and semantic annotation merge.
- Portable JSON-LD collaboration metadata embedded in ordinary Markdown.
- Deterministic native, CLI, collaboration, and MarginBench verification.
- GitHub Release packaging for the Apple-silicon Mac app plus CLI and standalone
  Linux CLI archives for x86-64 and ARM64.

## Near term

- Add Developer ID signing and notarization when OpenProse has the required
  Apple Developer credentials.
- Improve first-run installation and update guidance without adding a daemon or
  background service.
- Investigate whether the real editable-window path can be brought below 200 ms
  on the reference Mac. The v0.4.0 baseline is intentionally documented and
  gated above that target; do not advertise sub-200 ms until repeatable evidence
  supports it.
- Add a restrained product screenshot and social preview to the public project.
- Expand private MarginBench validation before making any general performance
  or agent-effectiveness claim.
- Consider a universal Mac build if Intel support becomes a requirement.

## Interchange

- Import and export generic W3C Annotation collections in addition to the
  current JSON-LD export.
- Add converters for review systems that can preserve text quotes, positions,
  authors, timestamps, and reply relationships.
- Extend durable audit/export options for edited and deleted comments beyond
  the current local conflict-aware Undo window.

## Optional semantic lenses

Any future model-assisted layer should remain optional and provider-neutral. It
should consume the same bounded interfaces agents use today rather than gaining
a second, privileged representation of the document.

Possible lenses include argument maps, decision logs, evidence checks, section
summaries, changed-passage views, and reply-tree synthesis into an inspectable
source suggestion. Generated work must identify its software actor, remain
separate from deterministic source operations, and never mutate a document
without an explicit application step.

## Enduring constraints

- Ordinary Markdown remains authoritative.
- The app launch path stays free of network, account, model, plug-in, and
  recursive indexing work.
- Collaboration mutations remain deterministic, inspectable, and safe to retry.
- Margin remains useful independently from OpenProse products and services.
