# Margin embedded comment protocol v1

Margin stores portable review discussions in the Markdown file they discuss. The payload follows the [W3C Web Annotation Data Model](https://www.w3.org/TR/annotation-model/) and adds a small `margin:` namespace for document integrity, thread state, and projection rules.

The goals are simple: ordinary Markdown tools should continue to work; humans and agents should share exactly one authority; concurrent writers should fail safely; and anchors should survive normal edits without silently moving to the wrong passage.

## Container

When a document has annotations, its final block is exactly:

```text
<!-- margin:comments:v1⏎
{ JSON-LD AnnotationPage }⏎
-->
```

Here `⏎` denotes a literal line feed; the glyph itself is not written.

The marker starts at column one and the block must be terminal. It is a CommonMark-compatible HTML comment, so ordinary Markdown renderers suppress it. A document with no annotations has no block.

Margin recognizes only that exact sentinel. Multiple blocks, a nonterminal block, malformed JSON, unsupported versions, or an integrity mismatch make mutation fail closed. Unrelated HTML comments are never interpreted as Margin data.

Because HTML comments cannot contain `--`, the canonical serializer escapes every hyphen inside JSON string values as `\u002d`. Decoding restores the original value.

## Envelope

The payload is a W3C `AnnotationPage` with this shape:

```json
{
  "@context": [
    "http://www.w3.org/ns/anno.jsonld",
    {"margin": "urn:margin:comments:v1:"}
  ],
  "id": "urn:uuid:DOCUMENT#comments",
  "type": "AnnotationPage",
  "partOf": {
    "id": "urn:uuid:DOCUMENT#collection",
    "type": "AnnotationCollection",
    "total": 1
  },
  "modified": "2026-08-16T04:00:00Z",
  "items": [],
  "margin:version": 1,
  "margin:revision": 1,
  "margin:document": {
    "id": "urn:uuid:DOCUMENT",
    "format": "text/markdown"
  },
  "margin:projection": "markdown-source-v1",
  "margin:contentByteLength": 123,
  "margin:contentSha256": "sha256:..."
}
```

`margin:contentByteLength` identifies the exact UTF-8 Markdown prefix. `margin:contentSha256` authenticates those same bytes. Padding inserted before the terminal comment is excluded. Unknown namespaced properties round-trip unchanged.

## Thread roots

A root is a W3C `Annotation` with `motivation: "commenting"`. Its body is an embedded `TextualBody` in `text/markdown`. The creator may be a `Person`, `Software`, or `Organization`.

A passage target is a `SpecificResource` with both selectors:

- `TextPositionSelector` gives a half-open Unicode code-point range.
- `TextQuoteSelector` stores the exact passage and up to 32 Unicode scalars of prefix and suffix context.

A document-level comment targets the document IRI directly. Only roots hold `margin:status`, either `open` or `resolved`; status applies to the entire reply tree.

## Replies

Every reply is another W3C `Annotation` with `motivation: "replying"`. Its target is the IRI of its parent annotation. Since a reply can target another reply, this standard relationship represents arbitrary-depth trees without a custom parent field.

Replying to a resolved thread fails unless the caller explicitly requests an atomic reopen-and-reply operation.

## Source projection and coordinates

`markdown-source-v1` means:

1. Decode the logical Markdown prefix as UTF-8.
2. Normalize CRLF and bare CR to LF.
3. Keep all literal Markdown characters.
4. Count positions in Unicode code points, with an end-exclusive range.

The app converts those positions to TextKit's UTF-16 ranges and refuses selections that split an extended grapheme cluster. CLI line and column coordinates are one-based grapheme positions; `--range` is explicitly Unicode code points.

## Anchor resolution

On load, Margin resolves a passage in this order:

1. Accept the stored position if it is in bounds and still equals `exact`.
2. Search for every exact quote occurrence.
3. If exactly one exists, use it.
4. For duplicates, score matching prefix and suffix context. Accept only a unique sufficiently strong best match.
5. Otherwise report `ambiguous` or `orphaned`; never guess by nearest position.

The app tracks live ranges while editing and refreshes both selectors on save. The CLI exposes explicit `reanchor` for ambiguous or orphaned roots.

## Concurrency and atomicity

The app and CLI share one mutation implementation. A writer:

1. Takes an exclusive lock derived from the canonical document path.
2. Rereads and validates the entire file.
3. Checks optional revision and content-hash preconditions.
4. Applies one semantic mutation.
5. Writes and synchronizes a same-directory temporary file while preserving permissions.
6. Verifies the original did not change, then atomically renames the replacement.

Explicit stale preconditions return a conflict. An idempotency ID replay with the same semantic payload returns the existing annotation; reuse with a different payload fails with `ID_CONFLICT`.

## Interchange

`margin comments export FILE --format jsonld` emits the `AnnotationPage` as JSON-LD. The Margin-specific properties may be retained by another implementation or removed when translating to a generic W3C Web Annotation collection. The W3C bodies, targets, selectors, creators, motivations, timestamps, and reply relationships remain directly reusable.
