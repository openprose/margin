# Open-source release handoff

This document records the handoff from Margin's internal development phase to
its first public GitHub release. It is deliberately a status record rather than
a release claim.

## Provenance

The current MarginBench work was developed and verified in Codex task
`01a00896-756f-7c92-992f-c41fbf9c4253`. The task's final checkpoint reported a
green native, benchmark, privacy, packaging, and smoke-test state. The repository
was left with that completed work uncommitted so it could be reviewed and
checkpointed as one coherent change.

## Decisions for the first public release

- The first public release will be `0.4.0`.
- The current MarginBench changes are part of that release.
- Open-source code will use Apache License 2.0 with copyright held by
  OpenProse, Inc.
- macOS distribution will provide one installer containing both `Margin.app`
  and the `margin` command-line tool.
- Linux distribution will provide standalone `margin` CLI archives for x86-64
  and ARM64. The Mac app is not required on Linux.
- The first macOS release will not have Developer ID signing or Apple
  notarization. Release documentation must describe the resulting Gatekeeper
  friction accurately and must not advise users to disable Gatekeeper globally.
- Margin is an independent tool used internally by the OpenProse team and
  opened for others to use. It is not the OpenProse product or a required part
  of the OpenProse platform.

## Evidence that may be stated publicly

- Margin is a native AppKit Markdown editor with a shared Swift core and CLI.
- Comments and collaboration metadata remain in the Markdown document as an
  ignorable JSON-LD envelope; no account or hosted service is required.
- The same collaboration core and CLI run on macOS and Linux.
- The repository contains deterministic native, CLI, collaboration, and
  MarginBench test surfaces.
- The public single-case stage-recovery comparison is useful development
  evidence, not a statistically meaningful performance or product claim.

## Loose threads

- Run the candidate against at least 20 fresh private cases before making a
  general MarginBench performance or superiority claim.
- Hosted MarginBench publication remains separate from the GitHub release and
  still needs the relevant external registry owner/handle.
- Add Developer ID Application and Installer certificates plus notarization
  credentials when OpenProse joins the Apple Developer Program.
- Decide later whether to add Intel Mac support. The first release remains
  aligned with the currently tested Apple-silicon requirement.
- Keep private holdout keys, raw traces, credentials, and generated run
  directories out of Git history and release artifacts.

## Publication checklist

The repository metadata, contributor and security policies, issue templates,
CI, version checks, Linux packaging, and tag-driven draft-release workflow are
now in place. The remaining publication steps require the public GitHub
repository:

1. Create an empty public `openprose/margin` repository without generated
   README, license, or ignore files.
2. Push the current branch and confirm the initial CI run.
3. Configure repository topics, private vulnerability reporting, and the
   desired branch-protection or ruleset policy.
4. Tag the verified commit as `v0.4.0`.
5. Review the workflow-created draft release, its four distribution artifacts,
   checksums, attestations, and generated notes before publishing it.

## Release boundary

The public repository contains Margin, its open collaboration protocol, and
public benchmark tooling. Future commercial OpenProse services or enterprise
features should remain separately packaged and licensed. The Margin name and
OpenProse identity remain trademarks even though the source is open.
