"""Fail-closed audit for a redacted public crossover evidence bundle."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .candidates import CandidateManifest
from .crossover import (
    CONTINUING_PROFILE,
    ROLE_SEPARATED_PROFILE,
    analyze_crossover,
    load_crossover_evidence_set,
)
from .schema import canonical_json, sha256_bytes
from .validation import MAX_ARTIFACT_BYTES, validate_bytes


PUBLICATION_AUDIT_SCHEMA = "urn:marginbench:crossover-publication-audit:v1"
MAX_PUBLICATION_FILES = 128
MAX_PUBLICATION_BYTES = 32 * 1_024 * 1_024
FORBIDDEN_SETTING_KEYS = {
    "accesskey",
    "apikey",
    "authorization",
    "credential",
    "credentials",
    "documenttext",
    "holdoutkey",
    "password",
    "privatekey",
    "prompt",
    "rawarguments",
    "rawprompt",
    "rawtrace",
    "secret",
    "stderr",
    "stdout",
    "trace",
    "transcript",
}
SENSITIVE_VALUE_PREFIXES = (
    "/",
    "~",
    "bearer ",
    "file://",
    "pit_",
    "sk-",
    "sk_",
    "ssh-ed25519 ",
    "ssh-rsa ",
    "-----begin private key",
)


class PublicationAuditError(ValueError):
    pass


def _strict_object(raw: bytes, label: str) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise PublicationAuditError(f"{label} contains non-finite JSON number {value}.")

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise PublicationAuditError(f"{label} contains duplicate key {key!r}.")
            result[key] = value
        return result

    try:
        text = raw.decode("utf-8")
        value = json.loads(
            text,
            parse_constant=reject_constant,
            object_pairs_hook=unique_object,
        )
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PublicationAuditError(f"{label} is not strict UTF-8 JSON.") from error
    if not isinstance(value, dict):
        raise PublicationAuditError(f"{label} must contain one JSON object.")
    return value


def _settings_are_public(values: dict[str, Any]) -> bool:
    stack: list[Any] = [values]
    visited = 0
    while stack:
        value = stack.pop()
        visited += 1
        if visited > 4096:
            return False
        if isinstance(value, dict):
            for key, item in value.items():
                normalized = "".join(character for character in key.lower() if character.isalnum())
                if normalized in FORBIDDEN_SETTING_KEYS:
                    return False
                stack.append(item)
        elif isinstance(value, list):
            stack.extend(value)
        elif isinstance(value, str) and value.strip().lower().startswith(SENSITIVE_VALUE_PREFIXES):
            return False
    return True


def _read(path: Path, relative: str) -> tuple[bytes, dict[str, Any], dict[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise PublicationAuditError(f"{relative} must be a regular non-symlink file.")
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise PublicationAuditError(f"{relative} could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise PublicationAuditError(f"{relative} exceeds the public artifact size bound.")
    value = _strict_object(raw, relative)
    receipt = validate_bytes(raw)
    if not receipt["valid"]:
        raise PublicationAuditError(f"{relative} failed its public schema or semantic checks.")
    return raw, value, receipt


def _artifact(relative: str, raw: bytes, receipt: dict[str, Any]) -> dict[str, Any]:
    return {
        "path": relative,
        "schema": receipt["artifactSchema"],
        "sha256": sha256_bytes(raw),
        "byteCount": len(raw),
    }


def _is_run_artifact(name: str) -> bool:
    return name.endswith((".run.json", "-run.json"))


def _is_summary_artifact(name: str) -> bool:
    return name.endswith((".summary.json", "-summary.json"))


def _expected_files(root: Path) -> tuple[list[Path], list[str], bool]:
    allowed_root = {
        "candidate-settings.json",
        "candidate.json",
        "crossover-plan.json",
        "crossover-prime-plan.json",
        "crossover-report.json",
        "cells",
    }
    unexpected: list[str] = []
    files: list[Path] = []
    seen = 0
    overflow = False

    def take(entries: os.ScandirIterator[str]) -> list[os.DirEntry[str]]:
        nonlocal seen, overflow
        selected: list[os.DirEntry[str]] = []
        for entry in entries:
            seen += 1
            if seen > MAX_PUBLICATION_FILES:
                overflow = True
                break
            selected.append(entry)
        return sorted(selected, key=lambda value: value.name)

    try:
        with os.scandir(root) as directory:
            entries = take(directory)
    except OSError as error:
        raise PublicationAuditError("The publication directory could not be listed.") from error
    for entry in entries:
        if entry.name not in allowed_root:
            unexpected.append(entry.name)
            continue
        if entry.name == "cells":
            if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                unexpected.append("cells")
                continue
            try:
                with os.scandir(entry.path) as directory:
                    children = take(directory)
            except OSError as error:
                raise PublicationAuditError("The cells directory could not be listed.") from error
            for child in children:
                relative = f"cells/{child.name}"
                if (
                    child.is_symlink()
                    or not child.is_file(follow_symlinks=False)
                    or not (_is_run_artifact(child.name) or _is_summary_artifact(child.name))
                ):
                    unexpected.append(relative)
                else:
                    files.append(Path(child.path))
        elif entry.is_file(follow_symlinks=False) and not entry.is_symlink():
            files.append(Path(entry.path))
        else:
            unexpected.append(entry.name)
    return sorted(files), sorted(unexpected), overflow


def _common_episode_fields(value: dict[str, Any], *, summary: bool) -> dict[str, Any]:
    result = {
        key: value.get(key)
        for key in (
            "agentProcessCount",
            "checks",
            "commandCount",
            "controlProfile",
            "dimensions",
            "durationMs",
            "fingerprint",
            "invalidCommandCount",
            "logicalActors",
            "marginSha256",
            "phasePolicy",
            "repetition",
            "safetyPassed",
            "scenario",
            "score",
            "sourcePreserved",
            "traceSeats",
            "usage",
        )
    }
    result["episodeID"] = value.get("episodeID" if summary else "id")
    return result


def audit_crossover_publication(root: Path) -> dict[str, Any]:
    """Audit one bounded publication directory without exposing absolute paths."""
    errors: list[dict[str, str]] = []
    artifacts: list[dict[str, Any]] = []
    candidate_id: str | None = None
    report_reproduced = False
    all_pairs_safe: bool | None = None
    sample_size_sufficient: bool | None = None
    run_count = 0
    summary_count = 0
    episode_count = 0

    def error(code: str, message: str, path: str | None = None) -> None:
        if len(errors) >= MAX_PUBLICATION_FILES:
            return
        item = {"code": code, "message": message}
        if path is not None:
            item["path"] = path
        errors.append(item)

    expanded = root.expanduser()
    resolved = expanded.resolve()
    if expanded.is_symlink() or not resolved.is_dir():
        error("INVALID_ROOT", "Publication root must be a non-symlink directory.")
        files: list[Path] = []
        unexpected: list[str] = []
        overflow = False
    else:
        try:
            files, unexpected, overflow = _expected_files(resolved)
        except PublicationAuditError as failure:
            error("DIRECTORY_READ_FAILED", str(failure))
            files, unexpected, overflow = [], [], False
    for value in unexpected:
        error("UNEXPECTED_ARTIFACT", "Unexpected or unsafe publication artifact.", value)
    if overflow:
        error("TOO_MANY_ARTIFACTS", "Publication exceeds the artifact-count bound.")

    aggregate_size = 0
    for path in files:
        try:
            aggregate_size += os.lstat(path).st_size
        except OSError:
            error("ARTIFACT_STAT_FAILED", "A publication artifact could not be inspected.")
    publication_too_large = aggregate_size > MAX_PUBLICATION_BYTES
    if publication_too_large:
        error("PUBLICATION_TOO_LARGE", "Publication exceeds the aggregate byte bound.")

    required = {
        "candidate-settings.json",
        "candidate.json",
        "crossover-plan.json",
        "crossover-report.json",
    }
    available = {
        path.relative_to(resolved).as_posix()
        for path in files
        if resolved.is_dir()
    }
    for missing in sorted(required - available):
        error("MISSING_ARTIFACT", "Required publication artifact is missing.", missing)

    values: dict[str, dict[str, Any]] = {}
    raws: dict[str, bytes] = {}
    total_bytes = 0
    for path in (() if publication_too_large else files):
        relative = path.relative_to(resolved).as_posix()
        if not relative.endswith(".json") or relative == "candidate-settings.json":
            continue
        try:
            raw, value, receipt = _read(path, relative)
        except PublicationAuditError as failure:
            error("INVALID_ARTIFACT", str(failure), relative)
            continue
        total_bytes += len(raw)
        raws[relative] = raw
        values[relative] = value
        artifacts.append(_artifact(relative, raw, receipt))
    if total_bytes > MAX_PUBLICATION_BYTES:
        error("PUBLICATION_TOO_LARGE", "Publication exceeds the aggregate byte bound.")

    settings_path = resolved / "candidate-settings.json"
    settings: dict[str, Any] | None = None
    if not publication_too_large and settings_path.is_file() and not settings_path.is_symlink():
        try:
            with settings_path.open("rb") as handle:
                raw = handle.read(128 * 1_024 + 1)
            if len(raw) > 128 * 1_024:
                raise PublicationAuditError("candidate-settings.json exceeds 128 KiB.")
            settings = _strict_object(raw, "candidate-settings.json")
            if not _settings_are_public(settings):
                error(
                    "PRIVATE_SETTINGS",
                    "Candidate settings contain a private or publication-unsafe field.",
                    "candidate-settings.json",
                )
        except (OSError, PublicationAuditError) as failure:
            error("INVALID_SETTINGS", str(failure), "candidate-settings.json")

    candidate = values.get("candidate.json")
    candidate_manifest: CandidateManifest | None = None
    if candidate is not None:
        try:
            candidate_manifest = CandidateManifest(**candidate)
            candidate_id = candidate_manifest.id
            if settings is None or canonical_json(settings) != canonical_json(candidate_manifest.settings):
                raise PublicationAuditError("Candidate settings do not match candidate.json.")
        except (TypeError, ValueError, PublicationAuditError) as failure:
            error("CANDIDATE_MISMATCH", str(failure), "candidate.json")

    plan = values.get("crossover-plan.json")
    report = values.get("crossover-report.json")
    if candidate_manifest is not None and plan is not None:
        if plan.get("candidateID") != candidate_manifest.id:
            error("PLAN_CANDIDATE_MISMATCH", "Plan names a different candidate.", "crossover-plan.json")

    prime_plan = values.get("crossover-prime-plan.json")
    if prime_plan is not None and candidate_manifest is not None and plan is not None:
        declared = prime_plan.get("candidate") or {}
        checks = {
            "manifestSha256": sha256_bytes(raws.get("candidate.json", b"")),
            "manifestDigest": candidate_manifest.digest(),
            "marginSha256": candidate_manifest.margin_sha256,
            "manualSha256": candidate_manifest.manual_sha256,
            "settingsSha256": candidate_manifest.settings_sha256,
        }
        if any(declared.get(key) != value for key, value in checks.items()):
            error("PRIME_CANDIDATE_MISMATCH", "Prime plan candidate digests do not match.", "crossover-prime-plan.json")
        if prime_plan.get("crossoverPlanSha256") != sha256_bytes(raws.get("crossover-plan.json", b"")):
            error("PRIME_PLAN_MISMATCH", "Prime plan does not bind this crossover plan.", "crossover-prime-plan.json")

    run_paths = sorted(
        resolved / relative
        for relative in values
        if relative.startswith("cells/") and _is_run_artifact(relative)
    )
    summary_paths = sorted(
        resolved / relative
        for relative in values
        if relative.startswith("cells/") and _is_summary_artifact(relative)
    )
    run_count = len(run_paths)
    summary_count = len(summary_paths)
    run_episodes: dict[tuple[str, str], dict[str, Any]] = {}
    summary_episodes: dict[tuple[str, str], dict[str, Any]] = {}
    for path in run_paths:
        relative = path.relative_to(resolved).as_posix()
        value = values[relative]
        if candidate_manifest is not None:
            declared = value.get("candidate") or {}
            if (
                declared.get("id") != candidate_manifest.id
                or declared.get("marginSha256") != candidate_manifest.margin_sha256
                or declared.get("manualSha256") != candidate_manifest.manual_sha256
                or declared.get("settingsSha256") != candidate_manifest.settings_sha256
            ):
                error("RUN_CANDIDATE_MISMATCH", "Run uses a different candidate bundle.", relative)
        for episode in value.get("episodes", []):
            key = (str(episode.get("id")), str(episode.get("controlProfile")))
            if key in run_episodes:
                error("DUPLICATE_RUN_EPISODE", "Run episode/profile appears more than once.", relative)
            run_episodes[key] = _common_episode_fields(episode, summary=False)

    for path in summary_paths:
        relative = path.relative_to(resolved).as_posix()
        value = values[relative]
        if candidate_manifest is not None and value.get("candidate") != candidate_manifest.id:
            error("SUMMARY_CANDIDATE_MISMATCH", "Summary uses a different candidate.", relative)
        for episode in value.get("episodes", []):
            key = (str(episode.get("episodeID")), str(episode.get("controlProfile")))
            if key in summary_episodes:
                error("DUPLICATE_SUMMARY_EPISODE", "Summary episode/profile appears more than once.", relative)
            summary_episodes[key] = _common_episode_fields(episode, summary=True)
    if run_episodes.keys() != summary_episodes.keys():
        error("RUN_SUMMARY_COVERAGE", "Run and summary episode/profile coverage differs.", "cells")
    else:
        for key in sorted(run_episodes):
            if canonical_json(run_episodes[key]) != canonical_json(summary_episodes[key]):
                error("RUN_SUMMARY_MISMATCH", "Run and summary disagree on episode facts.", "cells")
                break
    episode_count = len({identifier for identifier, _ in run_episodes})

    if plan is not None and report is not None and run_paths:
        try:
            separated = load_crossover_evidence_set([
                path for path in run_paths
                if values[path.relative_to(resolved).as_posix()]["execution"]["controlProfile"]
                == ROLE_SEPARATED_PROFILE
            ])
            continuing = load_crossover_evidence_set([
                path for path in run_paths
                if values[path.relative_to(resolved).as_posix()]["execution"]["controlProfile"]
                == CONTINUING_PROFILE
            ])
            if canonical_json(separated.experiment_contract) != canonical_json(continuing.experiment_contract):
                raise PublicationAuditError("Topology cells use different experiment contracts.")
            reproduced = analyze_crossover(
                separated.measurements,
                continuing.measurements,
                analysis_mode="measured-model",
                plan=plan,
                experiment_contract=separated.experiment_contract,
            )
            report_reproduced = canonical_json(reproduced) == canonical_json(report)
            if not report_reproduced:
                error("REPORT_MISMATCH", "Aggregate report is not reproduced by the published cells.", "crossover-report.json")
        except (ValueError, KeyError, TypeError):
            error(
                "REPORT_REPRODUCTION_FAILED",
                "Published cells could not reproduce the aggregate report.",
                "crossover-report.json",
            )
        all_pairs_safe = report.get("allPairsSafe")
        sample_size_sufficient = report.get("sampleSizeSufficient")

    artifacts.sort(key=lambda value: value["path"])
    errors.sort(key=lambda value: (value["code"], value.get("path", ""), value["message"]))
    return {
        "schema": PUBLICATION_AUDIT_SCHEMA,
        "valid": not errors,
        "rootName": resolved.name or "root",
        "candidateID": candidate_id,
        "artifactCount": len(artifacts),
        "runCount": run_count,
        "summaryCount": summary_count,
        "episodeCount": episode_count,
        "rawArtifactCount": min(len(unexpected), MAX_PUBLICATION_FILES),
        "reportReproduced": report_reproduced,
        "allPairsSafe": all_pairs_safe,
        "sampleSizeSufficient": sample_size_sufficient,
        "artifacts": artifacts,
        "errors": errors,
    }
