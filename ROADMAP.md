# Margin roadmap

## Monday v0.1

The release gate is the complete local human-agent review loop: native file and directory opening, literal Markdown editing, reader mode, embedded threaded comments, deterministic CLI reads and writes, concurrency safety, packaging, and measured launch performance.

## Later in the week: semantic lenses

The first model-assisted layer should remain optional and provider-neutral. It should consume the same bounded interfaces agents use today rather than gaining a second, privileged document representation.

Candidate lenses:

- **Zoom out:** argument map, decision log, open-question index, and section summaries.
- **Zoom in:** claims needing evidence, inconsistent terms, unresolved assumptions, and comments touching a passage.
- **Slice:** headings, line spans, threads, changed passages, semantic topics, and a token-budgeted context packet.
- **Synthesize:** reconcile a reply tree into a proposed source edit while retaining attribution and showing the exact patch.
- **Filter:** perspectives for architecture, editorial structure, accessibility, risk, implementation, or a named collaborator.

The model layer must be visibly separate from deterministic source operations. It should never mutate a document without an inspectable proposal and explicit application step. Generated feedback should identify its software actor, use idempotency keys, and write through the existing comment protocol.

## Interchange work

- Import/export generic W3C Annotation collections in addition to the current JSON-LD export.
- Add converters for review systems that can preserve text quotes, positions, authors, timestamps, and reply relationships.
- Specify a safe repair flow for Markdown changed by a non-Margin editor while retaining a stale comment envelope.
- Evaluate comment editing and deletion semantics without weakening auditability.

## Distribution work

- Add Developer ID signing and notarization when a certificate is available.
- Produce a universal binary if Intel support becomes a requirement.
- Keep the native core free of network, account, and plug-in startup costs.
