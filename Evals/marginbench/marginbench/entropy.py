"""Small deterministic HMAC stream used for public and private task generation."""

from __future__ import annotations

import hashlib
import hmac
import uuid


PUBLIC_DEVELOPMENT_KEY = hashlib.sha256(b"marginbench-public-development-v1").digest()


class HoldoutRandom:
    def __init__(self, key: bytes, domain: str):
        if len(key) < 16:
            raise ValueError("A benchmark key must contain at least 16 bytes.")
        self._key = key
        self._domain = domain.encode("utf-8")
        self._counter = 0
        self._buffer = bytearray()

    def bytes(self, count: int) -> bytes:
        if count < 0:
            raise ValueError("Byte count cannot be negative.")
        while len(self._buffer) < count:
            block = hmac.new(
                self._key,
                self._domain + b"\0" + self._counter.to_bytes(8, "big"),
                hashlib.sha256,
            ).digest()
            self._counter += 1
            self._buffer.extend(block)
        result = bytes(self._buffer[:count])
        del self._buffer[:count]
        return result

    def index(self, count: int) -> int:
        if count <= 0:
            raise ValueError("Choice set cannot be empty.")
        ceiling = (1 << 64) - ((1 << 64) % count)
        while True:
            value = int.from_bytes(self.bytes(8), "big")
            if value < ceiling:
                return value % count

    def choice(self, values):
        return values[self.index(len(values))]

    def shuffled(self, values):
        result = list(values)
        for index in range(len(result) - 1, 0, -1):
            swap = self.index(index + 1)
            result[index], result[swap] = result[swap], result[index]
        return result

    def uuid(self) -> str:
        raw = bytearray(self.bytes(16))
        raw[6] = (raw[6] & 0x0F) | 0x40
        raw[8] = (raw[8] & 0x3F) | 0x80
        return str(uuid.UUID(bytes=bytes(raw)))


def case_fingerprint(key: bytes, scenario_id: str, repetition: int) -> str:
    return hmac.new(
        key,
        f"marginbench:v1:{scenario_id}:{repetition}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
