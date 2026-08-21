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
from .challenges import challenge_catalog
from .checkpoint import CheckpointPromotionError, promote_checkpoint
from .controls import DEFAULT_CONTROL_PROFILE, control_catalog
from .concurrency_probe import ConcurrencyProbeLimits, run_concurrency_probe
from .convergence_probe import (
    SuggestionConvergenceLimits,
    run_suggestion_convergence_probe,
)
from .contention_matrix import ContentionMatrixLimits, run_contention_matrix
from .crossover import (
    CONTINUING_PROFILE,
    ROLE_SEPARATED_PROFILE,
    CrossoverMeasurement,
    analyze_crossover,
    build_crossover_plan,
    load_crossover_evidence_set,
    load_crossover_plan,
    reference_experiment_contract,
)
from .diagnostics import DiagnosticError, diagnose_artifacts
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .keys import create_holdout_key
from .plain_reference import run_plain_reference_episode
from .publication import audit_crossover_publication
from .reference_study import ReferenceStudyError, run_reference_study
from .runner import ReferenceDriver, run_episode
from .scheduling import ExecutionPlanError, build_execution_plan
from .scenarios import AVAILABLE_SCENARIO_IDS, SCENARIO_IDS, generate_episode
from .schema import canonical_json
from .studies import build_study_plan
from .submission import (
    SubmissionError,
    build_submission,
    verification_failure,
    verify_submission,
)
from .trace_shapes import TraceShapeError, summarize_trace_shapes
from .validation import validate_artifact
from .wide_directory_probe import ProbeLimits, run_wide_directory_probe


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
    generate.add_argument("--scenario", choices=AVAILABLE_SCENARIO_IDS, required=True)
    generate.add_argument("--repetition", type=int, default=0)
    generate.add_argument("--key-file")

    reference = subparsers.add_parser("reference", help="run the no-model reference policy")
    reference.add_argument(
        "--margin-bin",
        help="Margin executable; defaults to the verified binary bundled in the package.",
    )
    reference.add_argument("--scenario", action="append", choices=AVAILABLE_SCENARIO_IDS)
    reference.add_argument("--repetitions", type=int, default=1)
    reference.add_argument("--key-file")

    self_test = subparsers.add_parser("self-test", help="require every reference episode to score 100")
    self_test.add_argument(
        "--margin-bin",
        help="Margin executable; defaults to the verified binary bundled in the package.",
    )
    self_test.add_argument("--repetitions", type=int, default=1)

    neutral_feasibility = subparsers.add_parser(
        "neutral-feasibility",
        help="run no-model state checks for the plain-Markdown control",
    )
    neutral_feasibility.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    neutral_feasibility.add_argument("--repetitions", type=int, default=1)
    neutral_feasibility.add_argument("--key-file")

    neutral_served = subparsers.add_parser(
        "neutral-served-preflight",
        help="run the no-model Prime served check for the plain-Markdown control",
    )
    neutral_served.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    neutral_served.add_argument("--repetitions", type=int, default=1)
    neutral_served.add_argument("--key-file")

    neutral_isolation = subparsers.add_parser(
        "neutral-isolation-preflight",
        help="prove role transcript isolation with a local scripted endpoint",
    )
    neutral_isolation.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    neutral_isolation.add_argument("--repetitions", type=int, default=1)
    neutral_isolation.add_argument("--key-file")

    neutral_production = subparsers.add_parser(
        "neutral-production-preflight",
        help="rehearse the complete Prime plain-control result path with no paid model",
    )
    neutral_production.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    neutral_production.add_argument("--repetitions", type=int, default=1)

    neutral_prompt_audit = subparsers.add_parser(
        "neutral-prompt-audit",
        help="independently verify plain-control instruction equivalence without retaining prompts",
    )
    neutral_prompt_audit.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    neutral_prompt_audit.add_argument("--repetitions", type=int, default=5)
    neutral_prompt_audit.add_argument("--key-file")

    compare = subparsers.add_parser("compare", help="paired candidate comparison")
    compare.add_argument("baseline")
    compare.add_argument("candidate")

    wide_probe = subparsers.add_parser(
        "wide-directory-probe",
        help="compare brief-context size and latency on a deterministic wide workspace",
    )
    wide_probe.add_argument("--baseline-bin", required=True)
    wide_probe.add_argument("--candidate-bin", required=True)
    wide_probe.add_argument("--files", type=int, default=16)
    wide_probe.add_argument("--contributions-per-file", type=int, default=4)
    wide_probe.add_argument("--warmups", type=int, default=3)
    wide_probe.add_argument("--rounds", type=int, default=20)
    wide_probe.add_argument("--timeout-seconds", type=float, default=30.0)

    concurrency_probe = subparsers.add_parser(
        "concurrency-probe",
        help="compare agent-visible contention in repeated simultaneous two-writer episodes",
    )
    concurrency_probe.add_argument("--baseline-bin", required=True)
    concurrency_probe.add_argument("--candidate-bin", required=True)
    concurrency_probe.add_argument("--repetitions", type=int, default=100)

    convergence_probe = subparsers.add_parser(
        "suggestion-convergence-probe",
        help="compare repeated suggestion-list polling with one named durable wait",
    )
    convergence_probe.add_argument("--baseline-bin", required=True)
    convergence_probe.add_argument("--candidate-bin", required=True)
    convergence_probe.add_argument("--repetitions", type=int, default=4)
    convergence_probe.add_argument(
        "--delay-ms",
        action="append",
        type=int,
        help="delayed peer write in milliseconds; repeat to replace 200,500,1000",
    )
    convergence_probe.add_argument("--poll-interval-ms", type=int, default=50)
    convergence_probe.add_argument("--timeout-seconds", type=int, default=3)

    contention_matrix = subparsers.add_parser(
        "contention-matrix",
        help=(
            "compare operation-aware contention for typed work, individual and "
            "batched suggestions, decisions, and handoffs"
        ),
    )
    contention_matrix.add_argument("--baseline-bin", required=True)
    contention_matrix.add_argument("--candidate-bin", required=True)
    contention_matrix.add_argument("--repetitions", type=int, default=8)
    contention_matrix.add_argument(
        "--group-size",
        action="append",
        type=int,
        help="writer group size; repeat to replace the default 2,4,8,16 matrix",
    )
    contention_matrix.add_argument("--recovery-rounds", type=int, default=4)
    contention_matrix.add_argument("--timeout-seconds", type=float, default=30.0)

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
    study.add_argument("--scenario", action="append", choices=AVAILABLE_SCENARIO_IDS)
    study.add_argument("--repetitions", type=int, default=4)
    study.add_argument("--key-file")
    study.add_argument("--control-profile", default=DEFAULT_CONTROL_PROFILE)

    execution_plan = subparsers.add_parser(
        "execution-plan",
        help="flatten a paired study into deterministic candidate-ordered jobs",
    )
    execution_plan.add_argument("study_plan", type=Path)

    reference_study = subparsers.add_parser(
        "reference-study",
        help="run a complete paired study with the deterministic no-model reference policy",
    )
    reference_study.add_argument("output", type=Path)
    reference_study.add_argument("--study-plan", type=Path, required=True)
    reference_study.add_argument("--execution-plan", type=Path, required=True)
    reference_study.add_argument("--baseline-manifest", type=Path, required=True)
    reference_study.add_argument("--baseline-bin", type=Path, required=True)
    reference_study.add_argument("--candidate-manifest", type=Path, required=True)
    reference_study.add_argument("--candidate-bin", type=Path, required=True)
    reference_study.add_argument("--key-file", type=Path)

    subparsers.add_parser(
        "controls",
        help="show implemented and deliberately gated benchmark control profiles",
    )
    subparsers.add_parser(
        "challenges",
        help="show collaboration-demand profiles and crossover hypotheses",
    )

    crossover_plan = subparsers.add_parser(
        "crossover-plan",
        help="freeze matched cases and counterbalanced collaboration topologies",
    )
    crossover_plan.add_argument("--candidate", required=True)
    crossover_plan.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    crossover_plan.add_argument("--repetitions", type=int, default=3)
    crossover_plan.add_argument("--key-file")

    crossover_reference = subparsers.add_parser(
        "crossover-reference",
        help="measure both topologies with the deterministic no-model policy",
    )
    crossover_reference.add_argument(
        "--margin-bin",
        help="Margin executable; defaults to the verified binary bundled in the package.",
    )
    crossover_reference.add_argument("--scenario", action="append", choices=SCENARIO_IDS)
    crossover_reference.add_argument("--repetitions", type=int, default=3)
    crossover_reference.add_argument("--key-file")

    crossover_report = subparsers.add_parser(
        "crossover-report",
        help="compare completed role-separated and continuing-agent run artifacts",
    )
    crossover_report.add_argument("--plan", type=Path, required=True)
    crossover_report.add_argument("role_separated", type=Path, nargs="?")
    crossover_report.add_argument("continuing", type=Path, nargs="?")
    crossover_report.add_argument(
        "--role-separated-run",
        type=Path,
        action="append",
        default=[],
        help="completed role-separated cell; repeat for an interleaved study",
    )
    crossover_report.add_argument(
        "--continuing-run",
        type=Path,
        action="append",
        default=[],
        help="completed continuing-agent cell; repeat for an interleaved study",
    )

    keygen = subparsers.add_parser(
        "keygen",
        help="create a private rotating holdout key without printing its value",
    )
    keygen.add_argument("path")

    validate = subparsers.add_parser(
        "validate",
        help="validate a bounded public artifact against its schema and semantic totals",
    )
    validate.add_argument("artifact", help="JSON artifact path, or - for bounded stdin")

    audit_crossover = subparsers.add_parser(
        "audit-crossover",
        help="verify a complete redacted crossover publication bundle",
    )
    audit_crossover.add_argument("directory", type=Path)

    diagnose = subparsers.add_parser(
        "diagnose",
        help="rank privacy-preserving CLI and workflow opportunities from redacted results",
    )
    diagnose.add_argument(
        "artifact",
        type=Path,
        nargs="+",
        help=(
            "validated result/reference/run evidence, plus optional content-free "
            "trace-shape reports"
        ),
    )

    trace_shapes = subparsers.add_parser(
        "trace-shapes",
        help=(
            "summarize private Prime command shapes without retaining content, paths, "
            "or IDs; the report can supplement diagnose"
        ),
    )
    trace_shapes.add_argument(
        "trace",
        type=Path,
        nargs="+",
        help="private traces.jsonl file or raw run directory",
    )

    promote = subparsers.add_parser(
        "promote-checkpoint",
        help="validate and publish retained redacted artifacts without rerunning a paid model",
    )
    promote.add_argument("raw_directory", type=Path)
    promote.add_argument("--summary-file", type=Path, required=True)
    promote.add_argument("--run-file", type=Path, required=True)

    efficiency_report = subparsers.add_parser(
        "efficiency-report",
        help="project validated receipts and runs into a non-ranking resource report",
    )
    efficiency_report.add_argument(
        "artifact",
        type=Path,
        nargs="+",
        help="served-neutral receipt or redacted run artifact",
    )
    diagnose.add_argument(
        "--focus-candidate",
        help="candidate whose safety and opportunities control the recommendation",
    )

    submission = subparsers.add_parser(
        "submission",
        help="create or verify a digest-bound cross-artifact leaderboard submission",
    )
    submission_commands = submission.add_subparsers(dest="submission_command", required=True)
    submission_create = submission_commands.add_parser(
        "create",
        help="build a deterministic submission manifest after cross-checking every artifact",
    )
    submission_create.add_argument("root", type=Path)
    submission_create.add_argument("--baseline-manifest", type=Path, required=True)
    submission_create.add_argument("--candidate-manifest", type=Path, required=True)
    submission_create.add_argument("--study-plan", type=Path, required=True)
    submission_create.add_argument("--execution-plan", type=Path, required=True)
    submission_create.add_argument("--comparison", type=Path, required=True)
    submission_create.add_argument("--run", type=Path, action="append", required=True)
    submission_verify = submission_commands.add_parser(
        "verify",
        help="verify digests, schemas, study coverage, candidates, runs, and recomputed comparison",
    )
    submission_verify.add_argument("manifest", type=Path)

    arguments = parser.parse_args(argv)
    if arguments.command == "wide-directory-probe":
        _write(run_wide_directory_probe(
            _binary(arguments.baseline_bin),
            _binary(arguments.candidate_bin),
            limits=ProbeLimits(
                files=arguments.files,
                contributions_per_file=arguments.contributions_per_file,
                warmups=arguments.warmups,
                rounds=arguments.rounds,
                timeout_seconds=arguments.timeout_seconds,
            ),
        ))
        return 0
    if arguments.command == "concurrency-probe":
        _write(run_concurrency_probe(
            _binary(arguments.baseline_bin),
            _binary(arguments.candidate_bin),
            limits=ConcurrencyProbeLimits(repetitions=arguments.repetitions),
        ))
        return 0
    if arguments.command == "suggestion-convergence-probe":
        _write(run_suggestion_convergence_probe(
            _binary(arguments.baseline_bin),
            _binary(arguments.candidate_bin),
            limits=SuggestionConvergenceLimits(
                repetitions_per_delay=arguments.repetitions,
                delays_ms=tuple(arguments.delay_ms or (200, 500, 1_000)),
                poll_interval_ms=arguments.poll_interval_ms,
                timeout_seconds=arguments.timeout_seconds,
            ),
        ))
        return 0
    if arguments.command == "contention-matrix":
        _write(run_contention_matrix(
            _binary(arguments.baseline_bin),
            _binary(arguments.candidate_bin),
            limits=ContentionMatrixLimits(
                repetitions=arguments.repetitions,
                group_sizes=tuple(arguments.group_size or (2, 4, 8, 16)),
                recovery_rounds=arguments.recovery_rounds,
                timeout_seconds=arguments.timeout_seconds,
            ),
        ))
        return 0
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
    if arguments.command == "neutral-feasibility":
        if not 1 <= arguments.repetitions <= 100:
            raise ValueError("Neutral feasibility repetitions must be between 1 and 100.")
        scenarios = arguments.scenario or list(SCENARIO_IDS)
        key = _key(arguments.key_file)
        assessments = []
        for repetition in range(arguments.repetitions):
            for scenario in scenarios:
                episode = generate_episode(scenario, key, repetition)
                with tempfile.TemporaryDirectory(prefix="marginbench-neutral-") as temporary:
                    assessments.append(run_plain_reference_episode(
                        episode,
                        Path(temporary) / "workspace",
                    ))
        passed = all(
            all(assessment["checks"].values())
            and assessment["safetyPassed"]
            and assessment["sourcePreserved"]
            for assessment in assessments
        )
        _write({
            "schema": "urn:marginbench:neutral-feasibility:v1",
            "paidModelsInvoked": False,
            "controlProfile": "role-separated-plain-markdown-v1",
            "controlRunnable": True,
            "implementedChecksPassed": passed,
            "scenarioCount": len(set(scenarios)),
            "assessmentCount": len(assessments),
            "notEvaluated": ["efficiency"],
            "assessments": assessments,
        })
        return 0 if passed else 1
    if arguments.command == "neutral-served-preflight":
        try:
            from .plain_prime_preflight import run_plain_served_preflight
        except ImportError as error:
            raise ValueError(
                "Prime Verifiers dependencies are required for the served preflight."
            ) from error
        receipt = run_plain_served_preflight(
            scenarios=arguments.scenario or list(SCENARIO_IDS),
            repetitions=arguments.repetitions,
            key=_key(arguments.key_file),
        )
        _write(receipt)
        return 0 if receipt["passed"] else 1
    if arguments.command == "neutral-isolation-preflight":
        try:
            from .plain_isolation import run_plain_isolation_preflight
        except ImportError as error:
            raise ValueError(
                "Prime Verifiers dependencies are required for the isolation preflight."
            ) from error
        receipt = run_plain_isolation_preflight(
            scenarios=arguments.scenario or list(SCENARIO_IDS),
            repetitions=arguments.repetitions,
            key=_key(arguments.key_file),
        )
        _write(receipt)
        return 0 if receipt["passed"] else 1
    if arguments.command == "neutral-production-preflight":
        try:
            from .plain_production_preflight import run_plain_production_preflight
        except ImportError as error:
            raise ValueError(
                "Prime Verifiers dependencies are required for the production preflight."
            ) from error
        receipt = run_plain_production_preflight(
            scenarios=arguments.scenario or list(SCENARIO_IDS),
            repetitions=arguments.repetitions,
        )
        _write(receipt)
        return 0 if receipt["passed"] else 1
    if arguments.command == "neutral-prompt-audit":
        from .plain_prompt_audit import audit_plain_prompts

        receipt = audit_plain_prompts(
            scenarios=arguments.scenario or list(SCENARIO_IDS),
            repetitions=arguments.repetitions,
            key=_key(arguments.key_file),
        )
        _write(receipt)
        return 0 if receipt["passed"] else 1
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
            control_profile=arguments.control_profile,
        ))
        return 0
    if arguments.command == "execution-plan":
        try:
            _write(build_execution_plan(arguments.study_plan))
        except ExecutionPlanError as error:
            raise SystemExit(str(error)) from error
        return 0
    if arguments.command == "reference-study":
        try:
            receipt = run_reference_study(
                arguments.output,
                study_plan=arguments.study_plan,
                execution_plan=arguments.execution_plan,
                baseline_manifest=arguments.baseline_manifest,
                baseline_binary=arguments.baseline_bin,
                candidate_manifest=arguments.candidate_manifest,
                candidate_binary=arguments.candidate_bin,
                key_file=arguments.key_file,
                package_root=Path(__file__).resolve().parent.parent,
            )
        except ReferenceStudyError as error:
            raise SystemExit(str(error)) from error
        _write(receipt)
        return 0
    if arguments.command == "controls":
        _write(control_catalog())
        return 0
    if arguments.command == "challenges":
        _write(challenge_catalog())
        return 0
    if arguments.command == "crossover-plan":
        _write(build_crossover_plan(
            candidate=arguments.candidate,
            scenarios=arguments.scenario or list(SCENARIO_IDS),
            repetitions=arguments.repetitions,
            key=_key(arguments.key_file),
            development_cases=arguments.key_file is None,
        ))
        return 0
    if arguments.command == "crossover-reference":
        binary = _binary_or_packaged(arguments.margin_bin)
        scenarios = arguments.scenario or list(SCENARIO_IDS)
        key = _key(arguments.key_file)
        plan = build_crossover_plan(
            candidate="deterministic-reference-policy",
            scenarios=scenarios,
            repetitions=arguments.repetitions,
            key=key,
            development_cases=arguments.key_file is None,
        )
        profiles = {
            ROLE_SEPARATED_PROFILE: [],
            CONTINUING_PROFILE: [],
        }
        episodes = {
            episode.public_id: episode
            for repetition in range(arguments.repetitions)
            for scenario in scenarios
            for episode in (generate_episode(scenario, key, repetition),)
        }
        for planned in plan["episodes"]:
            episode = episodes[planned["id"]]
            for profile in planned["profileOrder"]:
                with tempfile.TemporaryDirectory(prefix="marginbench-crossover-") as temporary:
                    result = run_episode(
                        episode,
                        binary,
                        Path(temporary) / "workspace",
                        ReferenceDriver(),
                        candidate_id="deterministic-reference-policy",
                        control_profile=profile,
                    )
                profiles[profile].append(CrossoverMeasurement.from_result(
                    result,
                    scenario=episode.scenario_id,
                    repetition=episode.repetition,
                    fingerprint=episode.fingerprint,
                    control_profile=profile,
                ))
        _write(analyze_crossover(
            profiles[ROLE_SEPARATED_PROFILE],
            profiles[CONTINUING_PROFILE],
            analysis_mode="model-free-reference",
            plan=plan,
            experiment_contract=reference_experiment_contract(
                "deterministic-reference-policy",
                profiles[ROLE_SEPARATED_PROFILE][0].margin_sha256,
                {
                    role
                    for episode in plan["episodes"]
                    for role in episode["roles"]
                },
                task_set=plan["taskSet"],
                development_cases=plan["developmentCases"],
            ),
        ))
        return 0
    if arguments.command == "crossover-report":
        plan = load_crossover_plan(arguments.plan)
        separated_paths = [
            *([arguments.role_separated] if arguments.role_separated else []),
            *arguments.role_separated_run,
        ]
        continuing_paths = [
            *([arguments.continuing] if arguments.continuing else []),
            *arguments.continuing_run,
        ]
        separated = load_crossover_evidence_set(separated_paths)
        continuing = load_crossover_evidence_set(continuing_paths)
        if canonical_json(separated.experiment_contract) != canonical_json(
            continuing.experiment_contract
        ):
            raise ValueError(
                "Crossover runs differ in candidate, model, limits, runtime, retry, or cost policy."
            )
        _write(analyze_crossover(
            separated.measurements,
            continuing.measurements,
            analysis_mode="measured-model",
            plan=plan,
            experiment_contract=separated.experiment_contract,
        ))
        return 0
    if arguments.command == "keygen":
        _write(create_holdout_key(Path(arguments.path)))
        return 0
    if arguments.command == "validate":
        receipt = validate_artifact(Path(arguments.artifact))
        _write(receipt)
        return 0 if receipt["valid"] else 65
    if arguments.command == "audit-crossover":
        receipt = audit_crossover_publication(arguments.directory)
        _write(receipt)
        return 0 if receipt["valid"] else 65
    if arguments.command == "diagnose":
        try:
            _write(diagnose_artifacts(
                arguments.artifact,
                focus_candidate=arguments.focus_candidate,
            ))
        except DiagnosticError as error:
            raise SystemExit(str(error)) from error
        return 0
    if arguments.command == "trace-shapes":
        try:
            _write(summarize_trace_shapes(arguments.trace))
        except TraceShapeError as error:
            raise SystemExit(str(error)) from error
        return 0
    if arguments.command == "promote-checkpoint":
        try:
            receipt = promote_checkpoint(
                arguments.raw_directory,
                summary_file=arguments.summary_file,
                run_file=arguments.run_file,
            )
        except CheckpointPromotionError as error:
            raise SystemExit(str(error)) from error
        _write(receipt)
        return 0
    if arguments.command == "efficiency-report":
        # Keep the common command path light: the projection module is needed
        # only when this explicit offline report is requested.
        from .efficiency import build_efficiency_report

        _write(build_efficiency_report(arguments.artifact))
        return 0
    if arguments.command == "submission":
        if arguments.submission_command == "verify":
            receipt = verify_submission(arguments.manifest)
            _write(receipt)
            return 0 if receipt["valid"] else 65
        try:
            manifest = build_submission(
                arguments.root,
                baseline_manifest=arguments.baseline_manifest,
                candidate_manifest=arguments.candidate_manifest,
                study_plan=arguments.study_plan,
                execution_plan=arguments.execution_plan,
                comparison=arguments.comparison,
                runs=arguments.run,
            )
        except SubmissionError as error:
            _write(verification_failure(error.code, str(error)))
            return 65
        _write(manifest)
        return 0
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
