"""Safe creation of private rotating MarginBench task-generation keys."""

from __future__ import annotations

import hashlib
import os
import secrets
import stat
from pathlib import Path
from typing import Any


def create_holdout_key(path: Path) -> dict[str, Any]:
    """Create a new 256-bit key without ever returning or printing its value."""
    destination = Path(os.path.abspath(os.fspath(path.expanduser())))
    parent = destination.parent
    if not parent.is_dir():
        raise ValueError("The holdout-key parent directory must already exist.")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    value = (secrets.token_hex(32) + "\n").encode("ascii")
    try:
        descriptor = os.open(destination, flags, 0o600)
    except FileExistsError as error:
        raise ValueError("Refusing to replace an existing holdout-key file.") from error
    identity = os.fstat(descriptor)
    try:
        written = 0
        while written < len(value):
            count = os.write(descriptor, value[written:])
            if count <= 0:
                raise OSError("The holdout-key write did not make progress.")
            written += count
        os.fsync(descriptor)
    except Exception:
        os.close(descriptor)
        try:
            current = destination.lstat()
            if current.st_dev == identity.st_dev and current.st_ino == identity.st_ino:
                destination.unlink()
        except OSError:
            pass
        raise
    else:
        os.close(descriptor)
    if hasattr(os, "O_DIRECTORY"):
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    return {
        "schema": "urn:marginbench:holdout-key-receipt:v1",
        "created": True,
        "path": str(destination),
        "keyID": "sha256:" + hashlib.sha256(value.strip()).hexdigest(),
        "entropyBits": 256,
        "mode": "0600",
        "secretPrinted": False,
    }


def read_holdout_key(path: Path) -> tuple[bytes, str]:
    """Read a keygen-compatible secret once without following a final symlink."""
    target = path.expanduser()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(target, flags)
    except OSError as error:
        raise ValueError("Holdout key could not be read.") from error
    try:
        identity = os.fstat(descriptor)
        raw = os.read(descriptor, 257)
    finally:
        os.close(descriptor)
    if not stat.S_ISREG(identity.st_mode):
        raise ValueError("Holdout key must be a regular file.")
    if identity.st_size > 257:
        raise ValueError("Holdout key file is too large.")
    if identity.st_mode & 0o077:
        raise ValueError("Holdout key must not be group- or world-accessible.")
    value = raw.strip()
    try:
        value.decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("Holdout key must be ASCII.") from error
    if not 16 <= len(value) <= 256:
        raise ValueError("Holdout key must contain between 16 and 256 bytes.")
    return value, "sha256:" + hashlib.sha256(value).hexdigest()
