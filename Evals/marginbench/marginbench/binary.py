"""Resolve and verify the platform-specific Margin executable."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import tempfile
from pathlib import Path


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _manifest_path(package_directory: Path) -> Path | None:
    candidates = (
        package_directory / "manifest.json",
        package_directory.parent.parent / "BINARY_MANIFEST.json",
    )
    return next((path for path in candidates if path.is_file()), None)


def validate_packaged_binary(candidate: Path, package_directory: Path) -> bytes:
    manifest_path = _manifest_path(package_directory)
    if manifest_path is None:
        raise ValueError("The packaged Margin binary manifest is missing.")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("The packaged Margin binary manifest is unreadable.") from error
    if manifest.get("schema") != "urn:marginbench:binary-manifest:v1":
        raise ValueError("The packaged Margin binary manifest has an unsupported schema.")
    artifact = next(
        (
            item
            for item in manifest.get("artifacts", [])
            if isinstance(item, dict) and Path(str(item.get("path", ""))).name == candidate.name
        ),
        None,
    )
    if artifact is None:
        raise ValueError(f"The packaged binary {candidate.name!r} is not declared in its manifest.")
    data = candidate.read_bytes()
    expected_size = artifact.get("bytes")
    expected_digest = artifact.get("sha256")
    if expected_size != len(data) or expected_digest != _sha256(data):
        raise ValueError(f"The packaged binary {candidate.name!r} failed digest verification.")
    return data


def resolve_margin_binary(configured: str = "") -> Path:
    candidates: list[Path] = []
    if configured:
        candidates.append(Path(configured))
    if value := os.environ.get("MARGINBENCH_MARGIN_BIN"):
        candidates.append(Path(value))
    system = platform.system().lower()
    machine = platform.machine().lower()
    package_directory = Path(__file__).resolve().parent / "bin"
    candidates.append(package_directory / f"margin-{system}-{machine}")
    if found := shutil.which("margin"):
        candidates.append(Path(found))

    for candidate in candidates:
        resolved = candidate.expanduser().resolve()
        if not resolved.is_file():
            continue
        if resolved.parent != package_directory:
            if os.access(resolved, os.X_OK):
                return resolved
            continue

        data = validate_packaged_binary(resolved, package_directory)
        digest = _sha256(data)
        executable = Path(tempfile.gettempdir()) / "marginbench-binaries" / digest / "margin"
        executable.parent.mkdir(parents=True, exist_ok=True)
        if executable.exists():
            if _sha256(executable.read_bytes()) != digest:
                raise ValueError("The cached Margin executable failed digest verification.")
        else:
            temporary = executable.with_name(f".{executable.name}.{os.getpid()}.tmp")
            temporary.write_bytes(data)
            temporary.chmod(0o755)
            temporary.replace(executable)
        executable.chmod(0o755)
        return executable

    raise ValueError(
        "No Margin executable was found. Set --env.taskset.margin-binary or "
        "MARGINBENCH_MARGIN_BIN, or install a matching packaged binary."
    )
