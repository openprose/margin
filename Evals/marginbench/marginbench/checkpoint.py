"""Recover validated redacted artifacts from an immutable paid-run checkpoint."""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path
from typing import Any

from .schema import sha256_bytes
from .validation import MAX_ARTIFACT_BYTES, validate_bytes


CHECKPOINT_PROMOTION_SCHEMA = "urn:marginbench:checkpoint-promotion:v1"
ALLOWED_SCHEMA_PAIRS = {
    ("urn:marginbench:prime-run-summary:v1", "urn:marginbench:run:v1"),
    ("urn:marginbench:neutral-prime-run-summary:v1", "urn:marginbench:neutral-run:v1"),
}


class CheckpointPromotionError(ValueError):
    """A private checkpoint cannot safely be promoted."""


def _read_artifact(path: Path) -> tuple[bytes, dict[str, Any], dict[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise CheckpointPromotionError("Checkpoint artifacts must be regular non-symlink files.")
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise CheckpointPromotionError("Checkpoint artifact could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise CheckpointPromotionError("Checkpoint artifact exceeds the public size bound.")
    receipt = validate_bytes(raw)
    if not receipt["valid"]:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise CheckpointPromotionError(details or "Checkpoint artifact failed validation.")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CheckpointPromotionError("Checkpoint artifact is not strict UTF-8 JSON.") from error
    return raw, value, receipt


def _episode_key(value: dict[str, Any], *, summary: bool) -> str:
    key = "episodeID" if summary else "id"
    identifier = value.get(key)
    return identifier if isinstance(identifier, str) else ""


def _verify_pair(summary: dict[str, Any], run: dict[str, Any]) -> None:
    pair = (summary.get("schema"), run.get("schema"))
    if pair not in ALLOWED_SCHEMA_PAIRS:
        raise CheckpointPromotionError("Checkpoint summary and run schemas are not a supported pair.")
    if summary.get("status") != run.get("status"):
        raise CheckpointPromotionError("Checkpoint summary and run disagree on status.")
    run_candidate = run.get("candidate") if isinstance(run.get("candidate"), dict) else {}
    if summary.get("candidate") != run_candidate.get("id"):
        raise CheckpointPromotionError("Checkpoint summary and run disagree on candidate.")
    execution = run.get("execution") if isinstance(run.get("execution"), dict) else {}
    if summary.get("model") != execution.get("model"):
        raise CheckpointPromotionError("Checkpoint summary and run disagree on model.")
    summary_episodes = summary.get("episodes")
    run_episodes = run.get("episodes")
    if not isinstance(summary_episodes, list) or not isinstance(run_episodes, list):
        raise CheckpointPromotionError("Checkpoint summary and run must contain episode arrays.")
    summary_by_id = {
        _episode_key(value, summary=True): value
        for value in summary_episodes
        if isinstance(value, dict)
    }
    run_by_id = {
        _episode_key(value, summary=False): value
        for value in run_episodes
        if isinstance(value, dict)
    }
    if not summary_by_id or set(summary_by_id) != set(run_by_id):
        raise CheckpointPromotionError("Checkpoint summary and run disagree on episode coverage.")
    common_fields = (
        "scenario",
        "fingerprint",
        "repetition",
        "checks",
        "dimensions",
        "safetyPassed",
        "sourcePreserved",
    )
    for identifier, summary_episode in summary_by_id.items():
        run_episode = run_by_id[identifier]
        for field in common_fields:
            if summary_episode.get(field) != run_episode.get(field):
                raise CheckpointPromotionError(
                    f"Checkpoint summary and run disagree on episode field {field}."
                )
    summary_wallet = summary.get("wallet") if isinstance(summary.get("wallet"), dict) else {}
    run_cost = run.get("cost") if isinstance(run.get("cost"), dict) else {}
    if summary_wallet.get("observedDebitUSD") != run_cost.get("observedWalletDebit"):
        raise CheckpointPromotionError("Checkpoint summary and run disagree on observed cost.")


def _write_new_or_identical(path: Path, raw: bytes) -> str:
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise CheckpointPromotionError("Publication destination directory is unavailable.")
    if path.is_symlink():
        raise CheckpointPromotionError("Publication destination cannot be a symbolic link.")
    if path.exists():
        if not path.is_file() or path.read_bytes() != raw:
            raise CheckpointPromotionError("Publication destination already exists with other data.")
        return "already-present"

    temporary = parent / f".{path.name}.promote-{os.getpid()}-{uuid.uuid4().hex}"
    descriptor = -1
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short checkpoint write")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(temporary, path)
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except FileExistsError as error:
        raise CheckpointPromotionError("Publication destination appeared concurrently.") from error
    except OSError as error:
        raise CheckpointPromotionError("Checkpoint artifact could not be published atomically.") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return "created"


def promote_checkpoint(
    raw_directory: Path,
    *,
    summary_file: Path,
    run_file: Path,
) -> dict[str, Any]:
    """Validate, cross-check, and publish retained redacted paid-run artifacts."""
    root = raw_directory.expanduser()
    if root.is_symlink() or not root.is_dir():
        raise CheckpointPromotionError("Raw checkpoint directory is unavailable.")
    summary_raw, summary, summary_receipt = _read_artifact(root / "generated-summary.json")
    run_raw, run, run_receipt = _read_artifact(root / "generated-run.json")
    _verify_pair(summary, run)
    summary_disposition = _write_new_or_identical(summary_file.expanduser(), summary_raw)
    run_disposition = _write_new_or_identical(run_file.expanduser(), run_raw)
    status = (
        "already-present"
        if summary_disposition == run_disposition == "already-present"
        else "promoted"
    )
    return {
        "schema": CHECKPOINT_PROMOTION_SCHEMA,
        "status": status,
        "crossArtifactChecksPassed": True,
        "summary": {
            "schema": summary_receipt["artifactSchema"],
            "sha256": sha256_bytes(summary_raw),
            "byteCount": len(summary_raw),
            "disposition": summary_disposition,
        },
        "run": {
            "schema": run_receipt["artifactSchema"],
            "sha256": sha256_bytes(run_raw),
            "byteCount": len(run_raw),
            "disposition": run_disposition,
        },
    }
