# Contributing to Margin

Thank you for helping improve Margin. The project values focused changes that
keep Markdown portable, the native app fast, and human/agent behavior
deterministic.

## License and sign-off

Margin is licensed under the Apache License 2.0. Unless explicitly stated
otherwise, submitting a contribution means you license it to the project under
that license and have the right to do so.

Contributions use the [Developer Certificate of Origin](https://developercertificate.org/).
Add a `Signed-off-by` trailer to every commit:

```text
Signed-off-by: Your Name <you@example.com>
```

Git can add the trailer when creating a commit:

```sh
git commit --signoff
```

The sign-off is a certification of contribution rights, not a transfer of your
copyright.

## Development setup

The native app requires macOS 13 or newer and Swift 5.10 or newer. The portable
core and CLI also build on Linux. Margin has no third-party Swift package
dependencies.

On macOS, verify the main development surface from the repository root:

```sh
make test
make release
make smoke
```

Build outputs are written below `build/`; toolchain-specific Swift state is
kept below `.build/`. `make install` installs a local development build to
`~/Applications/Margin.app` and `~/.local/bin/margin` by default.

On Linux, or from a Mac with Docker available, run the portable gate:

```sh
make test-linux
```

See [Installing Margin](Docs/INSTALLATION.md) for source-build details and
[Margin architecture](Docs/ARCHITECTURE.md) for package boundaries.

## Run the tests that match the change

Start with the smallest relevant surface, then run the broader gate before
opening a pull request.

| Change | Minimum relevant checks |
| --- | --- |
| `MarginCore` or CLI | `make test`, `make test-linux` |
| AppKit UI or app behavior | `make test`, `make smoke` |
| Comment or collaboration protocol | `make test`, `make test-linux`, `make eval` |
| Directory transactions or agent workflow | `make eval-collaboration` |
| Launch-path behavior | `make smoke`, `make benchmark-matrix` |
| Packaging behavior | `make package` |
| MarginBench implementation or public evidence | `make marginbench-test`, `make marginbench-preflight` |

`make eval-preflight` and paid or remote benchmark runs are not routine pull
request requirements. They may invoke external models and must remain behind
their explicit budget and confirmation controls.

MarginBench development requires Python 3.11 or newer and its separately
pinned dependencies. Follow its [benchmark setup and safety instructions](Evals/marginbench/README.md)
before running that surface.

## Pull requests

Keep each pull request scoped to one coherent outcome. Include:

- the user-visible or protocol problem being solved;
- the important design and compatibility choices;
- tests added or changed and the commands run;
- screenshots or a short recording for visible UI changes;
- release-note or documentation updates when behavior, installation, or public
  contracts change;
- an explicit note for changes to persisted formats, CLI schemas, exit codes,
  or performance-sensitive startup work.

Preserve unknown namespaced protocol fields, literal Markdown bytes, stable
identities, bounded output, and fail-closed concurrency behavior. Avoid adding
work to application launch or ordinary file opening for a feature that can be
constructed on demand.

Do not edit historical benchmark artifacts merely to update names or versions.
Candidate manifests, result bundles, and digests are provenance records; change
them only through the benchmark's documented generation and verification flow.

## Generated and private material

Do not commit build products, Swift scratch directories, local benchmark runs,
raw traces, prompts, transcripts, generated fixtures, caches, credentials,
holdout keys, or other secrets. The repository ignore rules cover the normal
locations, including:

```text
.build/
.scratch/
build/
Evals/**/runs/
Evals/**/keys/
Evals/**/transcripts/
Evals/**/raw-prompts/
```

Ignore rules are a convenience, not a security boundary. Inspect the staged
diff before every commit. Public benchmark fixtures and redacted, verified
result bundles are allowed only when their documentation identifies them as
publishable evidence.

## Benchmark claims

Deterministic tests show that an implementation satisfies their stated
contracts; they do not establish broad model or product superiority. Do not
generalize from development cases, single runs, public fixtures, or small model
samples. Any performance or MarginBench claim in a pull request must link to a
reproducible artifact, name the exact candidates and environment, distinguish
public/development cases from private holdouts, and state material limitations.

## Security reports

Do not open a public issue for a suspected vulnerability or exposed secret.
Follow the private reporting instructions in [SECURITY.md](SECURITY.md). For
ordinary bugs and feature proposals, use the repository's GitHub issue forms.
