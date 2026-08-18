"""Reproducible digests for the benchmark implementation itself."""

from __future__ import annotations

import hashlib
from pathlib import Path


def implementation_files(package_root: Path) -> tuple[Path, ...]:
    """Return the code and contracts that can change an episode or its score.

    Results, generated packages, binaries, tests, documentation, caches, and
    private run data are deliberately outside this digest. The executable and
    manual have their own candidate digests in every run manifest.
    """
    package_root = package_root.resolve()
    explicit = (
        package_root / "pyproject.toml",
        package_root / "hatch_build.py",
        package_root / "paired_pilot.py",
        package_root / "preflight.py",
        package_root / "prime_pilot.py",
        package_root / "remote_runtime_probe.py",
    )
    discovered = tuple((package_root / "marginbench").rglob("*.py")) + tuple(
        (package_root / "schemas" / "v1").glob("*.json")
    )
    files = {
        path.resolve()
        for path in (*explicit, *discovered)
        if path.is_file() and "__pycache__" not in path.parts
    }
    return tuple(sorted(files, key=lambda path: path.relative_to(package_root).as_posix()))


def implementation_sha256(package_root: Path) -> str:
    """Hash relative names, byte lengths, and bytes without filesystem metadata."""
    package_root = package_root.resolve()
    digest = hashlib.sha256()
    for path in implementation_files(package_root):
        relative = path.relative_to(package_root).as_posix().encode("utf-8")
        content = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()
