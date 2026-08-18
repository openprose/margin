"""Deterministic, cross-artifact MarginBench leaderboard submissions."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from .candidates import paired_compare
from .schema import EpisodeResult, canonical_json
from .validation import MAX_ARTIFACT_BYTES, submission_identifier, validate_bytes


SUBMISSION_SCHEMA = "urn:marginbench:submission:v1"
VERIFICATION_SCHEMA = "urn:marginbench:submission-verification:v1"
MAX_ERRORS = 32
MAX_SUBMISSION_BYTES = 64 * 1_024 * 1_024


class SubmissionError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message[:1024])
        self.code = code


def _root(path: Path) -> Path:
    root = path.expanduser().resolve()
    if not root.is_dir():
        raise SubmissionError("SUBMISSION_ROOT_INVALID", "Submission root is not a directory.")
    return root


def _relative_argument(root: Path, value: Path) -> str:
    candidate = value.expanduser()
    if not candidate.is_absolute():
        candidate = root / candidate
    resolved = candidate.resolve()
    try:
        relative = resolved.relative_to(root)
    except ValueError as error:
        raise SubmissionError(
            "SUBMISSION_PATH_ESCAPE",
            "Every submission artifact must remain inside the submission root.",
        ) from error
    if not resolved.is_file() or candidate.is_symlink():
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_UNAVAILABLE",
            "A submission artifact is unavailable or is a symbolic link.",
        )
    rendered = PurePosixPath(relative.as_posix()).as_posix()
    if rendered in {"", "."}:
        raise SubmissionError("SUBMISSION_PATH_INVALID", "Artifact path must name a file.")
    return rendered


def _resolved_reference(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != relative:
        raise SubmissionError("SUBMISSION_PATH_INVALID", "Artifact path is not canonical.")
    candidate = root.joinpath(*path.parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise SubmissionError("SUBMISSION_PATH_ESCAPE", "Artifact path leaves the submission root.") from error
    if not resolved.is_file() or candidate.is_symlink():
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_UNAVAILABLE",
            f"Artifact is unavailable or is a symbolic link: {relative[:200]}",
        )
    return resolved


def _read_snapshot(path: Path) -> bytes:
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_UNAVAILABLE",
            "A submission artifact could not be read.",
        ) from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_TOO_LARGE",
            f"A submission artifact exceeds {MAX_ARTIFACT_BYTES} bytes.",
        )
    return raw


def _load(
    root: Path,
    relative: str,
    expected_schema: str,
    expected_sha256: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    target = _resolved_reference(root, relative)
    raw = _read_snapshot(target)
    receipt = validate_bytes(raw)
    if not receipt["valid"]:
        detail = "; ".join(receipt["errors"][:3])
        if not detail and receipt["error"]:
            detail = receipt["error"]["message"]
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_INVALID",
            f"Artifact {relative[:200]} is invalid: {detail[:700]}",
        )
    if receipt["artifactSchema"] != expected_schema:
        raise SubmissionError(
            "SUBMISSION_ARTIFACT_SCHEMA",
            f"Artifact {relative[:200]} has the wrong schema.",
        )
    if expected_sha256 is not None and receipt["sha256"] != expected_sha256:
        raise SubmissionError(
            "SUBMISSION_DIGEST_MISMATCH",
            f"Artifact digest does not match the submission manifest: {relative[:200]}",
        )
    # Parse the exact bytes whose schema and digest were checked. Reading the
    # path a second time would allow a concurrent replacement to split the
    # evidence receipt from the payload used for cross-artifact verification.
    payload = json.loads(raw)
    evidence = {
        "path": relative,
        "schema": receipt["artifactSchema"],
        "sha256": receipt["sha256"],
        "byteCount": receipt["byteCount"],
    }
    return payload, evidence


def _candidate_fields(candidate: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": candidate["id"],
        "marginSha256": candidate["margin_sha256"],
        "manualSha256": candidate["manual_sha256"],
        "settingsSha256": candidate["settings_sha256"],
    }


def _execution_profile(run: dict[str, Any], fields: tuple[str, ...]) -> bytes:
    execution = run["execution"]
    return canonical_json({field: execution.get(field) for field in fields})


def _episode_result(episode: dict[str, Any], candidate: dict[str, Any]) -> EpisodeResult:
    required = ("sourcePreserved", "durationMs", "marginSha256")
    missing = [field for field in required if field not in episode]
    if missing:
        raise SubmissionError(
            "SUBMISSION_RUN_TOO_OLD",
            f"Run episode lacks publication fields required for comparison: {', '.join(missing)}",
        )
    return EpisodeResult(
        episode_id=episode["id"],
        candidate_id=candidate["id"],
        score=episode["score"],
        dimensions=episode["dimensions"],
        checks=episode["checks"],
        command_count=episode["commandCount"],
        invalid_command_count=episode["invalidCommandCount"],
        duration_ms=episode["durationMs"],
        safety_passed=episode["safetyPassed"],
        source_preserved=episode["sourcePreserved"],
        margin_sha256=episode["marginSha256"],
    )


def _cross_errors(manifest: dict[str, Any], loaded: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    baseline = loaded[manifest["baseline"]["path"]]
    candidate = loaded[manifest["candidate"]["path"]]
    study = loaded[manifest["studyPlan"]["path"]]
    execution_plan = loaded[manifest["executionPlan"]["path"]]
    comparison = loaded[manifest["comparison"]["path"]]
    candidates = {baseline["id"]: baseline, candidate["id"]: candidate}

    if manifest["baseline"]["id"] != baseline["id"]:
        errors.append("baseline candidate reference does not match its manifest")
    if manifest["candidate"]["id"] != candidate["id"]:
        errors.append("candidate reference does not match its manifest")
    if study["baselineCandidate"] != baseline["id"] or study["candidate"] != candidate["id"]:
        errors.append("study plan candidates do not match the submission")
    if (
        execution_plan["studyPlanSha256"] != manifest["studyPlan"]["sha256"]
        or execution_plan["baselineCandidate"] != baseline["id"]
        or execution_plan["candidate"] != candidate["id"]
    ):
        errors.append("execution plan does not match the submission study and candidates")
    try:
        from .scheduling import build_execution_plan_from_study

        expected_execution = build_execution_plan_from_study(
            study,
            manifest["studyPlan"]["sha256"],
        )
        if expected_execution != execution_plan:
            errors.append("execution plan is not the deterministic expansion of the study plan")
    except (KeyError, TypeError, ValueError, RuntimeError) as error:
        errors.append(f"execution plan could not be recomputed: {str(error)[:400]}")
    if comparison["baselineCandidateID"] != baseline["id"] or comparison["candidateID"] != candidate["id"]:
        errors.append("comparison candidates do not match the submission")
    if comparison["minimumPairsForPromotion"] != study["minimumPairsForPromotion"]:
        errors.append("comparison promotion threshold does not match the study plan")
    if (
        comparison["baselineMarginSha256"] != baseline["margin_sha256"]
        or comparison["candidateMarginSha256"] != candidate["margin_sha256"]
    ):
        errors.append("comparison Margin builds do not match the candidate manifests")

    common = (
        ("benchmarkVersion", study["benchmarkVersion"]),
        ("taskSet", study["taskSet"]),
        ("developmentCases", study["developmentCases"]),
        ("controlProfile", study["controlProfile"]),
    )
    for field, value in common:
        if manifest[field] != value:
            errors.append(f"submission {field} does not match the study plan")

    study_episodes = {item["id"]: item for item in study["episodes"]}
    episodes_by_candidate: dict[str, dict[str, dict[str, Any]]] = {
        baseline["id"]: {},
        candidate["id"]: {},
    }
    executions_by_candidate: dict[str, list[dict[str, Any]]] = {
        baseline["id"]: [],
        candidate["id"]: [],
    }
    for reference in manifest["runs"]:
        run = loaded[reference["path"]]
        referenced_id = reference["candidateID"]
        run_id = run["candidate"]["id"]
        if referenced_id != run_id or run_id not in candidates:
            errors.append(f"run candidate reference is inconsistent: {reference['path'][:200]}")
            continue
        expected_candidate = _candidate_fields(candidates[run_id])
        if run["candidate"] != expected_candidate:
            errors.append(f"run candidate digests are inconsistent: {reference['path'][:200]}")
        if run["benchmark"].get("implementationSha256") != manifest["benchmarkImplementationSha256"]:
            errors.append(f"run benchmark implementation is inconsistent: {reference['path'][:200]}")
        if run["status"] != "completed":
            errors.append(f"leaderboard run is not completed: {reference['path'][:200]}")
        if run["track"] != manifest["track"]:
            errors.append(f"run track is inconsistent: {reference['path'][:200]}")
        if (
            run["benchmark"]["version"] != manifest["benchmarkVersion"]
            or run["benchmark"]["taskSet"] != manifest["taskSet"]
            or run["benchmark"]["developmentCases"] != manifest["developmentCases"]
        ):
            errors.append(f"run benchmark identity is inconsistent: {reference['path'][:200]}")
        if run["execution"].get("controlProfile") != manifest["controlProfile"]:
            errors.append(f"run control profile is inconsistent: {reference['path'][:200]}")
        executions_by_candidate[run_id].append(run)
        destination = episodes_by_candidate[run_id]
        expected_run_roles: set[str] = set()
        for episode in run["episodes"]:
            identifier = episode["id"]
            if identifier in destination:
                errors.append(f"candidate has a duplicate episode across runs: {identifier[:200]}")
            destination[identifier] = episode
            planned = study_episodes.get(identifier)
            if planned is not None:
                expected_run_roles.update(planned["roles"])
        if set(run["execution"]["roles"]) != expected_run_roles:
            errors.append(f"run role set does not match its study episodes: {reference['path'][:200]}")

    full_profile_fields = (
        "adapter", "provider", "model", "harness", "runtime",
        "controlProfile", "limits", "retryPolicy",
    )
    track = manifest["track"]
    profile_by_candidate: dict[str, bytes] = {}
    for identifier, runs in executions_by_candidate.items():
        profiles = {_execution_profile(run, full_profile_fields) for run in runs}
        if track != "open-systems" and len(profiles) != 1:
            errors.append(f"candidate runs use inconsistent execution controls: {identifier[:200]}")
        elif profiles:
            profile_by_candidate[identifier] = next(iter(profiles))

    baseline_bundle = _candidate_fields(baseline)
    candidate_bundle = _candidate_fields(candidate)
    if len(profile_by_candidate) == 2:
        baseline_runs = executions_by_candidate[baseline["id"]]
        candidate_runs = executions_by_candidate[candidate["id"]]
        if track == "interface" and (
            profile_by_candidate[baseline["id"]] != profile_by_candidate[candidate["id"]]
        ):
            errors.append("interface-track candidates use different execution controls")
        elif track == "model":
            fixed_fields = tuple(
                field for field in full_profile_fields if field not in {"provider", "model"}
            )
            if _execution_profile(baseline_runs[0], fixed_fields) != _execution_profile(
                candidate_runs[0], fixed_fields
            ):
                errors.append("model-track candidates use different non-model controls")
            if any(
                baseline_bundle[field] != candidate_bundle[field]
                for field in ("marginSha256", "manualSha256", "settingsSha256")
            ):
                errors.append("model-track candidates do not use the same Margin bundle")
        elif track == "team":
            fixed_fields = (
                "provider", "model", "runtime", "controlProfile", "limits", "retryPolicy",
            )
            if _execution_profile(baseline_runs[0], fixed_fields) != _execution_profile(
                candidate_runs[0], fixed_fields
            ):
                errors.append("team-track candidates use different fixed execution controls")
            if any(
                baseline_bundle[field] != candidate_bundle[field]
                for field in ("marginSha256", "manualSha256")
            ):
                errors.append("team-track candidates do not use the same Margin interface")

    expected_ids = set(study_episodes)
    for identifier, values in episodes_by_candidate.items():
        if set(values) != expected_ids:
            errors.append(f"candidate run coverage does not match the study plan: {identifier[:200]}")
        for episode_id, episode in values.items():
            planned = study_episodes.get(episode_id)
            if planned is None:
                continue
            if any(
                episode[field] != planned[field]
                for field in ("scenario", "repetition", "fingerprint")
            ):
                errors.append(f"run episode identity differs from the study plan: {episode_id[:200]}")
            if episode.get("marginSha256") != candidates[identifier]["margin_sha256"]:
                errors.append(f"run episode Margin digest differs from its candidate: {episode_id[:200]}")

    if not errors:
        try:
            expected_comparison = paired_compare(
                (
                    _episode_result(episodes_by_candidate[baseline["id"]][identifier], baseline)
                    for identifier in sorted(expected_ids)
                ),
                (
                    _episode_result(episodes_by_candidate[candidate["id"]][identifier], candidate)
                    for identifier in sorted(expected_ids)
                ),
                minimum_pairs=study["minimumPairsForPromotion"],
            )
            if expected_comparison != comparison:
                errors.append("comparison does not equal the deterministic recomputation from runs")
        except (KeyError, TypeError, ValueError, SubmissionError) as error:
            errors.append(f"comparison could not be recomputed: {str(error)[:400]}")
    return errors[:MAX_ERRORS]


def _references(manifest: dict[str, Any]) -> list[tuple[dict[str, Any], str]]:
    values = [
        (manifest["baseline"], "urn:marginbench:candidate:v1"),
        (manifest["candidate"], "urn:marginbench:candidate:v1"),
        (manifest["studyPlan"], "urn:marginbench:study-plan:v1"),
        (manifest["executionPlan"], "urn:marginbench:execution-plan:v1"),
        (manifest["comparison"], "urn:marginbench:paired-comparison:v1"),
    ]
    values.extend((item, "urn:marginbench:run:v1") for item in manifest["runs"])
    return values


def _preflight_aggregate_size(
    root: Path,
    references: list[tuple[dict[str, Any], str]],
) -> None:
    total = 0
    for reference, _ in references:
        target = _resolved_reference(root, reference["path"])
        try:
            size = target.stat().st_size
        except OSError as error:
            raise SubmissionError(
                "SUBMISSION_ARTIFACT_UNAVAILABLE",
                "A submission artifact could not be inspected.",
            ) from error
        if size > MAX_ARTIFACT_BYTES:
            raise SubmissionError(
                "SUBMISSION_ARTIFACT_TOO_LARGE",
                f"A submission artifact exceeds {MAX_ARTIFACT_BYTES} bytes.",
            )
        total += size
        if total > MAX_SUBMISSION_BYTES:
            raise SubmissionError(
                "SUBMISSION_TOO_LARGE",
                f"Submission evidence exceeds the {MAX_SUBMISSION_BYTES}-byte aggregate limit.",
            )


def _verify_manifest(
    manifest: dict[str, Any],
    root: Path,
) -> tuple[list[dict[str, Any]], list[str]]:
    references = _references(manifest)
    _preflight_aggregate_size(root, references)
    loaded: dict[str, dict[str, Any]] = {}
    artifacts: list[dict[str, Any]] = []
    errors: list[str] = []
    for reference, schema in references:
        try:
            payload, evidence = _load(
                root,
                reference["path"],
                schema,
                reference["sha256"],
            )
            loaded[reference["path"]] = payload
            artifacts.append(evidence)
        except SubmissionError as error:
            errors.append(str(error))
            if len(errors) >= MAX_ERRORS:
                break
    if not errors and len(loaded) == len(references):
        errors.extend(_cross_errors(manifest, loaded))
    return sorted(artifacts, key=lambda item: item["path"]), errors[:MAX_ERRORS]


def build_submission(
    root: Path,
    *,
    baseline_manifest: Path,
    candidate_manifest: Path,
    study_plan: Path,
    execution_plan: Path,
    comparison: Path,
    runs: Iterable[Path],
) -> dict[str, Any]:
    root = _root(root)
    paths = {
        "baseline": _relative_argument(root, baseline_manifest),
        "candidate": _relative_argument(root, candidate_manifest),
        "study": _relative_argument(root, study_plan),
        "execution": _relative_argument(root, execution_plan),
        "comparison": _relative_argument(root, comparison),
    }
    run_paths = [_relative_argument(root, value) for value in runs]
    if len(run_paths) < 2:
        raise SubmissionError("SUBMISSION_RUNS_MISSING", "Submission requires at least two run manifests.")
    if len(run_paths) != len(set(run_paths)):
        raise SubmissionError("SUBMISSION_RUN_DUPLICATE", "Submission run paths must be unique.")

    baseline, baseline_evidence = _load(root, paths["baseline"], "urn:marginbench:candidate:v1")
    candidate, candidate_evidence = _load(root, paths["candidate"], "urn:marginbench:candidate:v1")
    study, study_evidence = _load(root, paths["study"], "urn:marginbench:study-plan:v1")
    _, execution_evidence = _load(
        root,
        paths["execution"],
        "urn:marginbench:execution-plan:v1",
    )
    _, comparison_evidence = _load(
        root,
        paths["comparison"],
        "urn:marginbench:paired-comparison:v1",
    )
    run_references: list[dict[str, Any]] = []
    run_tracks: set[str] = set()
    implementation_digests: set[str] = set()
    for path in sorted(run_paths):
        run, evidence = _load(root, path, "urn:marginbench:run:v1")
        run_tracks.add(run["track"])
        implementation = run["benchmark"].get("implementationSha256")
        if not implementation:
            raise SubmissionError(
                "SUBMISSION_RUN_TOO_OLD",
                "A run lacks the benchmark implementation digest required for publication.",
            )
        implementation_digests.add(implementation)
        run_references.append({
            "candidateID": run["candidate"]["id"],
            "path": path,
            "sha256": evidence["sha256"],
        })
    if len(run_tracks) != 1:
        raise SubmissionError("SUBMISSION_TRACK_MISMATCH", "All runs must use one benchmark track.")
    if len(implementation_digests) != 1:
        raise SubmissionError(
            "SUBMISSION_IMPLEMENTATION_MISMATCH",
            "All runs must use one benchmark implementation.",
        )

    manifest = {
        "schema": SUBMISSION_SCHEMA,
        "benchmarkVersion": study["benchmarkVersion"],
        "benchmarkImplementationSha256": next(iter(implementation_digests)),
        "taskSet": study["taskSet"],
        "track": next(iter(run_tracks)),
        "developmentCases": study["developmentCases"],
        "controlProfile": study["controlProfile"],
        "baseline": {
            "id": baseline["id"],
            "path": paths["baseline"],
            "sha256": baseline_evidence["sha256"],
        },
        "candidate": {
            "id": candidate["id"],
            "path": paths["candidate"],
            "sha256": candidate_evidence["sha256"],
        },
        "studyPlan": {"path": paths["study"], "sha256": study_evidence["sha256"]},
        "executionPlan": {
            "path": paths["execution"],
            "sha256": execution_evidence["sha256"],
        },
        "comparison": {
            "path": paths["comparison"],
            "sha256": comparison_evidence["sha256"],
        },
        "runs": run_references,
        "privacy": {
            "rawTracesIncluded": False,
            "credentialsIncluded": False,
            "holdoutKeyIncluded": False,
        },
    }
    manifest["id"] = submission_identifier(manifest)
    receipt = validate_bytes(canonical_json(manifest))
    if not receipt["valid"]:
        raise SubmissionError("SUBMISSION_MANIFEST_INVALID", "; ".join(receipt["errors"][:3]))
    _, errors = _verify_manifest(manifest, root)
    if errors:
        raise SubmissionError("SUBMISSION_INCONSISTENT", "; ".join(errors[:3]))
    return manifest


def verification_failure(code: str, message: str) -> dict[str, Any]:
    return {
        "schema": VERIFICATION_SCHEMA,
        "valid": False,
        "submissionID": None,
        "manifestSha256": None,
        "artifactCount": 0,
        "artifacts": [],
        "error": {"code": code, "message": message[:1024]},
        "errors": [],
    }


def verify_submission(path: Path) -> dict[str, Any]:
    manifest_path = path.expanduser().resolve()
    try:
        raw = _read_snapshot(manifest_path)
    except SubmissionError as error:
        return verification_failure(error.code, str(error))
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != SUBMISSION_SCHEMA:
        detail = "; ".join(receipt.get("errors", ())[:3])
        error = receipt.get("error") or {"code": "SUBMISSION_MANIFEST_INVALID", "message": ""}
        return {
            **verification_failure(error["code"], detail or error["message"]),
            "manifestSha256": receipt.get("sha256"),
            "errors": receipt.get("errors", ())[:MAX_ERRORS],
        }
    manifest = json.loads(raw)
    try:
        root = _root(manifest_path.parent)
        artifacts, errors = _verify_manifest(manifest, root)
    except SubmissionError as error:
        return {
            **verification_failure(error.code, str(error)),
            "submissionID": manifest["id"],
            "manifestSha256": receipt["sha256"],
        }
    valid = not errors
    result = {
        "schema": VERIFICATION_SCHEMA,
        "valid": valid,
        "submissionID": manifest["id"],
        "manifestSha256": receipt["sha256"],
        "artifactCount": len(artifacts),
        "artifacts": artifacts,
        "error": None if valid else {
            "code": "SUBMISSION_INCONSISTENT",
            "message": f"Submission failed {len(errors)} cross-artifact check(s).",
        },
        "errors": errors,
    }
    checked = validate_bytes(canonical_json(result))
    if not checked["valid"]:
        raise RuntimeError("Submission verification receipt violated its own schema.")
    return result
