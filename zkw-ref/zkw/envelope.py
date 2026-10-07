"""Fixed 512-byte memo envelope and chunking (spec section 7, revised in v0.2).

Layout (all integers big-endian):
  0   2  magic "ZW"
  2   1  version (0x01)
  3   1  type
  4   8  conv_tag
  12  1  chunk_index (0-based)
  13  1  chunk_total (1..MAX_CHUNKS)
  14  8  msg_id (random; shared by all chunks of one logical message)
  22  2  body_len
  24  n  body
  24+n   random padding to 512

v0.2 change from v0.1: a 2-byte body_len was added (offset 22) so random padding
can be stripped, and chunk index/total are one byte each.
"""
from __future__ import annotations

import struct
import time
from dataclasses import dataclass

from . import primitives as P

MEMO_LEN = 512
HEADER_LEN = 24
MAX_BODY = MEMO_LEN - HEADER_LEN  # 488
MAGIC = b"ZW"
VERSION = 1
MAX_CHUNKS = 15

T_HELLO = 0x01
T_BUNDLE = 0x02
T_INIT = 0x03
T_MSG = 0x10
T_RECEIPT = 0x11
T_REACTION = 0x12
T_KEY_UPDATE = 0x13
T_CLOSE = 0x7F
KNOWN_TYPES = {T_HELLO, T_BUNDLE, T_INIT, T_MSG, T_RECEIPT, T_REACTION, T_KEY_UPDATE, T_CLOSE}


@dataclass(frozen=True)
class Envelope:
    type: int
    conv_tag: bytes
    chunk_index: int
    chunk_total: int
    msg_id: bytes
    body: bytes

    def encode(self, pad: bytes | None = None) -> bytes:
        if self.type not in KNOWN_TYPES:
            raise P.CryptoError("unknown type")
        if len(self.conv_tag) != 8 or len(self.msg_id) != 8:
            raise P.CryptoError("bad tag or id length")
        if not (1 <= self.chunk_total <= MAX_CHUNKS and 0 <= self.chunk_index < self.chunk_total):
            raise P.CryptoError("bad chunk numbering")
        if len(self.body) > MAX_BODY:
            raise P.CryptoError("body too large")
        head = MAGIC + bytes([VERSION, self.type]) + self.conv_tag + bytes([self.chunk_index, self.chunk_total]) \
            + self.msg_id + struct.pack(">H", len(self.body))
        fill = MEMO_LEN - HEADER_LEN - len(self.body)
        pad = P.rand(fill) if pad is None else pad[:fill]
        out = head + self.body + pad
        assert len(out) == MEMO_LEN
        return out

    @classmethod
    def decode(cls, memo: bytes) -> "Envelope | None":
        """Returns None for memos that are not ours (plain wallet memos, other apps)."""
        if len(memo) != MEMO_LEN or memo[:2] != MAGIC:
            return None
        if memo[2] != VERSION:
            return None
        t = memo[3]
        idx, total = memo[12], memo[13]
        blen = struct.unpack(">H", memo[22:24])[0]
        if t not in KNOWN_TYPES or blen > MAX_BODY or not (1 <= total <= MAX_CHUNKS and idx < total):
            return None
        return cls(t, memo[4:12], idx, total, memo[14:22], memo[24:24 + blen])


def split(type_: int, conv_tag: bytes, payload: bytes, msg_id: bytes | None = None) -> list[bytes]:
    """Split a payload into encoded memos. All memos go into ONE transaction (ZIP-321 multi-output)."""
    msg_id = P.rand(8) if msg_id is None else msg_id
    parts = [payload[i:i + MAX_BODY] for i in range(0, len(payload), MAX_BODY)] or [b""]
    if len(parts) > MAX_CHUNKS:
        raise P.CryptoError("payload needs too many memos")
    return [Envelope(type_, conv_tag, i, len(parts), msg_id, p).encode() for i, p in enumerate(parts)]


class Reassembler:
    """Collects chunks. Chunks of one message arrive in the same transaction, but the
    wallet may surface outputs in any order, so we key on (msg_id) and wait for all."""

    def __init__(self, ttl_s: int = 3600):
        self._pending: dict[bytes, tuple[float, int, int, bytes, dict[int, bytes]]] = {}
        self._ttl = ttl_s

    def add(self, env: Envelope, now: float | None = None) -> tuple[int, bytes, bytes] | None:
        """Returns (type, conv_tag, payload) once complete, else None."""
        now = time.time() if now is None else now
        self._expire(now)
        if env.chunk_total == 1:
            return env.type, env.conv_tag, env.body
        entry = self._pending.get(env.msg_id)
        if entry is None:
            entry = (now, env.type, env.chunk_total, env.conv_tag, {})
            self._pending[env.msg_id] = entry
        _, t, total, tag, parts = entry
        if (t, total, tag) != (env.type, env.chunk_total, env.conv_tag):
            return None  # inconsistent chunk; ignore
        parts[env.chunk_index] = env.body
        if len(parts) == total:
            del self._pending[env.msg_id]
            return t, tag, b"".join(parts[i] for i in range(total))
        return None

    def _expire(self, now: float) -> None:
        for k in [k for k, v in self._pending.items() if now - v[0] > self._ttl]:
            del self._pending[k]
