# Conditional Mutation Exercise

This document is intentionally short so the task measures safe writes rather than reading volume.

## Contract

The release token identifies one immutable approval decision.

## Coordination

Agents must make retries idempotent and reject stale compare-and-swap state.

## Result

Two independent comments should survive without changing this prose.
