# Watcher Handoff

The document records how humans and agents exchange review state without rewriting prose.

## Ordering

The event contract must define what happens when a writer swaps the file during watcher startup.

## Retry Policy

The retry window is bounded and conditional mutations never retry a stale explicit precondition.

## Launch Decision

The first release favors deterministic review primitives over an embedded language-model layer.

## Compatibility

Every comment remains portable W3C annotation data inside an invisible terminal envelope.
