# Atlas Launch Review

This artifact is intentionally fixed so that different agents receive the same review task.

## Objective

Margin's launch budget should be felt as immediacy, not merely reported as a benchmark.

Cold start must stay below 45 milliseconds on the baseline Mac.

## Signals

During the first rehearsal, the shared signal appeared before the sidebar finished drawing.

During the second rehearsal, the shared signal appeared only after the document was readable.

The second observation is the one that should receive an agent comment.

## Compatibility

The first release supports macOS 13 and later while keeping the Markdown source portable.

## Decision

Ship the smallest coherent review loop: inspect, read, comment, reply, and resolve.
