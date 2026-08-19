# Margin architecture

Margin is a small native editor and cross-platform collaboration engine built
around one rule: the Markdown document remains the authority. The application
and CLI share the same Swift core, and neither requires a server, database,
daemon, account, or model provider.

## Package boundaries

```text
MarginApp (macOS only)              MarginCLI (macOS and Linux)
├── AppKit window and menus         ├── static manual and capability catalog
├── directory navigator            ├── bounded reads and reviews
├── literal Markdown editor        ├── deterministic mutations
├── reader presentation            ├── stable JSON/error contracts
└── review inspectors              └── macOS-only app launcher
              │                                  │
              └──────────────┬───────────────────┘
                             ▼
                         MarginCore
              ├── Markdown inspection and outlines
              ├── Unicode coordinates and resilient anchors
              ├── embedded JSON-LD serialization
              ├── atomic document persistence and locking
              ├── review snapshots and comment services
              ├── bounded contexts, cursors, and activity
              ├── suggestions, handoffs, and typed contributions
              ├── immutable stages and recovery transactions
              └── reconciliation and semantic merge
```

`Package.swift` always exposes the `MarginCore` library and `margin-cli`
executable. It adds `MarginAppBinary` and its tests only on macOS. The release
scripts rename the `margin-cli` executable to `margin` for distribution.

The Swift products have no third-party runtime dependencies. MarginBench under
`Evals/marginbench` is separate Python evaluation infrastructure; it is absent
from the app and CLI startup path.

## Document model

The bytes before Margin's envelope are the logical Markdown body. When a file
has annotations, a terminal CommonMark HTML comment contains a W3C Web
Annotation JSON-LD page with threads, actors, status, resilient selectors, and
integrity metadata. Ordinary Markdown renderers ignore the block, while Margin
hides it from source editing and reader presentation.

Text positions use a normalized Unicode-code-point projection. Passage anchors
combine positions with exact quote and surrounding context. Resolution accepts
an exact stored position, relocates a uniquely matching quote, or reports an
ambiguous/orphaned anchor; it does not guess.

The canonical formats are documented in the
[embedded comment protocol](../COMMENT_PROTOCOL.md) and
[directory collaboration protocol](COLLABORATION_PROTOCOL.md).

## Persistence and concurrency

Single-document writes use a lock derived from the canonical path, reread the
file under that lock, check optional revision and digest preconditions, create a
complete validated replacement, preserve file metadata, and atomically rename
the replacement into place. Stable mutation IDs make safe retries idempotent.

An optional `.margin` workspace contains:

```text
.margin/
├── workspace.json   # stable workspace identity and selection rules
├── stages/          # immutable pending operation plans
├── transactions/    # short-lived crash-recovery journals
└── activity/        # bounded immutable collaboration facts
```

Multi-file submission acquires document locks in canonical order plus a root
submission lock, validates every input and output before installation, and uses
a durable write-ahead journal for rollback or recovery. Workspace-consistent
Margin reads share the submission lock. POSIX cannot atomically rename several
independent files at once, so external readers may observe the brief interval
between installs; individual files remain atomically valid throughout.

Reconciliation is an explicit, fail-closed recovery path for source changed
outside Margin. Semantic merge compares annotation graphs by stable identity
and requires explicit choices for competing changes.

## Application structure

`AppDelegate` and `AppMenu` own process-level application behavior.
`WorkspaceWindowController` coordinates native windows, tabs, the optional
navigator, the editor/reader surface, and the comment inspector.

The editor keeps literal Markdown source in TextKit. Syntax styling uses
temporary attributes and does not alter document bytes. Reader presentation,
directory indexing, filesystem watching, collaboration overviews, and stage
presentation are created only when requested so they do not join the initial
window path.

The application stores only lightweight local presentation state such as open
tabs, pane visibility, selection, scroll position, and the active thread. An
explicit file or directory supplied by the user takes precedence over session
restoration.

## CLI contract

The CLI is a thin, deterministic interface over `MarginCore`:

- `margin man` provides progressive workflow guidance;
- `margin capabilities --json` provides the bounded versioned command contract;
- `margin COMMAND --help` provides exact local grammar;
- read operations are bounded and report truncation;
- mutations emit one JSON object on standard output;
- errors emit structured details on standard error with stable codes and
  sysexits-compatible statuses.

The application launcher is the only platform-specific CLI behavior. On Linux,
launcher forms return `APP_UNAVAILABLE`; the complete file and collaboration
command set remains available. See the [CLI guide](CLI.md).

## Performance rules

The launch path performs no network request, recursive directory scan,
workspace aggregation, benchmark work, or model initialization. Directory
navigation enumerates a folder only when it becomes visible. Optional review
and reader surfaces are lazy. Release acceptance includes launch, memory,
source-stability, protocol, concurrency, and packaging checks.

## Verification layers

- `Tests/MarginCoreTests`: codecs, anchors, Unicode coordinates, concurrency,
  transactions, recovery, bounded context, reconciliation, and merge.
- `Tests/MarginCLITests`: command contracts, launcher behavior, and event-driven
  watching.
- `Tests/MarginAppTests`: native presentation, workspace behavior, reader/editor
  integration, accessibility, and lazy UI boundaries.
- `Evals/cli`: deterministic single-document agent workflows.
- `Evals/collaboration`: multi-file and multi-actor workflow gates.
- `Evals/marginbench`: provider-independent benchmark contracts and optional
  adapters, packaged separately from Margin itself.

Build and test commands are listed in [CONTRIBUTING.md](../CONTRIBUTING.md).
