# Distributed Launch Architecture

This synthetic architecture note is deliberately broad enough to reward selective reading.

## Executive Frame

The launch has three control planes, two storage paths, and one human escalation channel.
The review goal is to find decisions that affect ordering, ownership, and recovery.

## Request Admission

Admission nodes reject malformed tenants before allocating durable work.
Each accepted request receives a monotonic local sequence and an opaque trace identifier.
Admission is intentionally independent from deployment orchestration.

## Event Ordering

Watchers register before the initial snapshot so atomic replacements cannot vanish between phases.
Duplicate notifications are collapsed by document identity and comment revision.
Consumers treat a missing intermediate revision as coalescing rather than data loss.

## Regional Routing

The region failover path moves new traffic only after the secondary control plane is healthy.
Existing sessions drain against their original region unless an operator forces evacuation.
The route ledger records who initiated every transition and why.

## Cache Discipline

The cache invalidation sequence publishes the durable version before evicting local readers.
Readers compare a content digest before trusting a cached parse.
No cache entry owns source-of-truth status.

## Durable Storage

Writers stage a complete sibling file, synchronize it, and atomically replace the destination.
File modes and extended metadata survive the replacement where the platform permits.
The containing directory is synchronized after rename.

## Audit Pipeline

The audit sink receives mutation receipts without raw comment bodies.
Records include stable error codes, timing, actor identity, and revision transitions.
Retention must be explicit because the audit path is not a document archive.

## Agent Contract

Agents use bounded review snapshots and targeted slices before requesting full source.
Every mutation returns a machine-readable receipt suitable for the next action.
Failed compare-and-swap attempts never mutate the envelope.

## Human Escalation

The operator rehearsal covers service degradation, filesystem replacement, and stale state.
One incident lead owns the decision while agents supply evidence and alternatives.
The runbook favors explicit handoffs over ambient chat history.

## Schema Migration

The schema migration preserves unknown namespaced fields and refuses unsupported future versions.
Converters may project annotations into other standards without changing Markdown prose.
Malformed terminal metadata remains visible to diagnostics and is never silently discarded.

## Performance Envelope

Directory enumeration stays lazy and rendering never blocks first window presentation.
Comment parsing is cached until the protected terminal region changes.
Measurements distinguish framework startup cost from document work.

## Decision Ledger

The first release keeps the region failover decision human-owned.
Conditional retries are capped, observable, and disabled for explicit stale preconditions.
All source text remains portable when Margin is absent.

## Deferred Work

Language-model filters and summaries remain outside the deterministic review core.
Remote collaboration can build on the same annotation identities and revision protocol.
The CLI is the reference interface for agents and automation.

## Acceptance

The system passes when a human can see exactly what changed, why it changed, and who changed it.
The system also passes when an agent can recover safely from stale state without rewriting prose.
Both paths must remain responsive on a large workspace.
