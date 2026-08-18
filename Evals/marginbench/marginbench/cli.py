"""Local MarginBench commands; none invoke a model or a paid service."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from dataclasses import asdict
from pathlib import Path

from .binary import resolve_margin_binary
from .candidates import CandidateManifest, load_results, paired_compare
from .controls import control_catalog
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .keys import create_holdout_key
from .runner import ReferenceDriver, run_episode
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import canonical_json
from .studies import build_study_plan


def _key(path: str | None) -> bytes:
    if not path:
        return PUBLIC_DEVELOPMENT_KEY
    value = Path(path).read_bytes().strip()
    if len(value) < 16:
        raise ValueError("Key file must contain at least 16 bytes.")
    return value


def _binary(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"Margin executable is unavailable: {path}")
    return path


def _binary_or_packaged(value: str | None) -> Path:
    return _binary(value) if value else resolve_margin_binary()


def _write(value) -> None:
    print(canonical_json(value).decode("utf-8"))


def _settings(path: str | None, inline: str | None) -> dict:
    if path is None and inline is None:
        return {}
    raw = inline.encode("utf-8") if inline is not None else Path(path).read_bytes()
    if len(raw) > 128 * 1_024:
        raise ValueError("Candidate settings exceed the 128 KiB bound.")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Candidate settings must be a JSON object.")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="marginbench")
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate = subparsers.add_parser("generate", help="emit a public episode manifest")
    generate.add_argument("--scenario", choices=SCENARIO_IDS, required=True)
    generate.add_argument("--repetition", type=int, default=0)
    generate.add_argument("--key-file")

    reference = subparsers.add_parser("reference", help="run the no-model reference policy")
    reference.add_argument(
        "--margin-bin",
        help="Margin executable; defaults to the verified binary bundled in the package.",
    )
    reference.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    reference.add_argument("--repetitions", type=int, default=1)
    reference.add_argument("--key-file")

    self_test = subparsers.add_parser("self-test", help="require every reference episode to score 100")
    self_test.add_argument(
        "--margin-bin",
        help="Margin executable; defaults to the verified binary bundled in the package.",
    )
    self_test.add_argument("--repetitions", type=int, default=1)

    compare = subparsers.add_parser("compare", help="paired candidate comparison")
    compare.add_argument("baseline")
    compare.add_argument("candidate")

    candidate = subparsers.add_parser("candidate", help="freeze a CLI/manual/settings candidate by digest")
    candidate.add_argument("--id", required=True)
    candidate.add_argument("--margin-bin", required=True)
    candidate.add_argument("--manual")
    settings = candidate.add_mutually_exclusive_group()
    settings.add_argument("--settings-file")
    settings.add_argument("--settings-json")

    study = subparsers.add_parser(
        "study-plan",
        help="freeze paired cases and counterbalanced candidate order without running models",
    )
    study.add_argument("--baseline", required=True)
    study.add_argument("--candidate", required=True)
    study.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    study.add_argument("--repetitions", type=int, default=4)
    study.add_argument("--key-file")

    subparsers.add_parser(
        "controls",
        help="show implemented and deliberately gated benchmark control profiles",
    )

    keygen = subparsers.add_parser(
        "keygen",
        help="create a private rotating holdout key without printing its value",
    )
    keygen.add_argument("path")

    arguments = parser.parse_args(argv)
    if arguments.command == "generate":
        episode = generate_episode(arguments.scenario, _key(arguments.key_file), arguments.repetition)
        _write(episode.public_manifest())
        return 0
    if arguments.command in {"reference", "self-test"}:
        binary = _binary_or_packaged(arguments.margin_bin)
        scenarios = arguments.scenario if arguments.command == "reference" and arguments.scenario else list(SCENARIO_IDS)
        key = _key(getattr(arguments, "key_file", None))
        results = []
        for repetition in range(arguments.repetitions):
            for scenario in scenarios:
                episode = generate_episode(scenario, key, repetition)
                with tempfile.TemporaryDirectory(prefix="marginbench-reference-") as temporary:
                    result = run_episode(
                        episode,
                        binary,
                        Path(temporary) / "workspace",
                        ReferenceDriver(),
                    )
                results.append(result.to_dict())
                if arguments.command == "self-test" and result.score != 100.0:
                    _write({"schema": "urn:marginbench:self-test:v1", "passed": False, "result": result.to_dict()})
                    return 1
        passed = all(result["score"] == 100.0 for result in results)
        if arguments.command == "self-test":
            _write({
                "schema": "urn:marginbench:self-test:v1",
                "paidModelsInvoked": False,
                "passed": passed,
                "episodeCount": len(results),
                "scenarioCount": len(scenarios),
                "minimumScore": min((result["score"] for result in results), default=None),
                "safetyPassed": all(result["safety_passed"] for result in results),
            })
        else:
            _write({
                "schema": "urn:marginbench:reference-run:v1",
                "paidModelsInvoked": False,
                "passed": passed,
                "results": results,
            })
        return 0
    if arguments.command == "compare":
        _write(paired_compare(load_results(Path(arguments.baseline)), load_results(Path(arguments.candidate))))
        return 0
    if arguments.command == "candidate":
        manual = Path(arguments.manual).expanduser().resolve() if arguments.manual else None
        if manual is not None and not manual.is_file():
            raise ValueError(f"Manual source is unavailable: {manual}")
        manifest = CandidateManifest.create(
            arguments.id,
            _binary(arguments.margin_bin),
            manual=manual,
            settings=_settings(arguments.settings_file, arguments.settings_json),
        )
        _write(asdict(manifest))
        return 0
    if arguments.command == "study-plan":
        scenarios = arguments.scenario or list(SCENARIO_IDS)
        _write(build_study_plan(
            baseline=arguments.baseline,
            candidate=arguments.candidate,
            scenarios=scenarios,
            repetitions=arguments.repetitions,
            key=_key(arguments.key_file),
            development_cases=arguments.key_file is None,
        ))
        return 0
    if arguments.command == "controls":
        _write(control_catalog())
        return 0
    if arguments.command == "keygen":
        _write(create_holdout_key(Path(arguments.path)))
        return 0
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
