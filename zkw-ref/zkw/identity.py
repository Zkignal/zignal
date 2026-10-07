"""Identity keys, signed prekeys, safety numbers, and the QR/link invite (spec sections 3-4)."""
from __future__ import annotations

import hashlib
import struct
import time
from dataclasses import dataclass, field

from . import primitives as P

SPK_LIFETIME_S = 7 * 24 * 3600
SPK_GRACE_S = 14 * 24 * 3600  # accept INIT against an expired prekey for this long (spec 9)


@dataclass
class Identity:
    """Long-term messaging identity, deterministically derived from the wallet seed."""
    sig: object  # Ed25519PrivateKey
    dh: object   # X25519PrivateKey

    @classmethod
    def from_seed(cls, seed: bytes) -> "Identity":
        if len(seed) < 32:
            raise P.CryptoError("seed must be at least 32 bytes")
        okm = P.hkdf(seed, salt=b"zkw", info=P.L_IDENTITY, length=64)
        return cls(sig=P.ed25519_from_seed(okm[:32]), dh=P.x25519_from_bytes(okm[32:]))

    @property
    def sig_pub(self) -> bytes:
        return P.ed25519_pub_bytes(self.sig)

    @property
    def dh_pub(self) -> bytes:
        return P.x25519_pub_bytes(self.dh)

    def binding_sig(self) -> bytes:
        """Proves the X25519 identity key belongs to this Ed25519 identity."""
        return P.sign(self.sig, P.L_ID_BIND, self.dh_pub)


def verify_binding(sig_pub: bytes, dh_pub: bytes, sig: bytes) -> None:
    P.verify(sig_pub, P.L_ID_BIND, dh_pub, sig)


def safety_number(sig_pub_a: bytes, sig_pub_b: bytes) -> str:
    """60 digits, identical on both devices regardless of who computes it."""
    lo, hi = sorted([sig_pub_a, sig_pub_b])
    digest = hashlib.sha512(P.L_SAFETY + lo + hi).digest()[:60]
    groups = [int.from_bytes(digest[i:i + 5], "big") % 100000 for i in range(0, 60, 5)]
    return " ".join(f"{g:05d}" for g in groups)


@dataclass
class SignedPrekey:
    id: int
    priv: object  # X25519PrivateKey
    created: int


@dataclass
class PQPrekey:
    id: int
    priv: object  # MLKEM768PrivateKey
    created: int


@dataclass
class PrekeyStore:
    """Owner side: current prekeys plus recently retired ones (kept for the grace window)."""
    identity: Identity
    spks: dict[int, SignedPrekey] = field(default_factory=dict)
    pqspks: dict[int, PQPrekey] = field(default_factory=dict)
    current_spk: int = 0
    current_pqspk: int = 0
    _next_id: int = 1

    def rotate(self, now: int | None = None) -> None:
        now = int(time.time()) if now is None else now
        sid, self._next_id = self._next_id, self._next_id + 1
        self.spks[sid] = SignedPrekey(sid, P.x25519_gen(), now)
        self.current_spk = sid
        pid, self._next_id = self._next_id, self._next_id + 1
        self.pqspks[pid] = PQPrekey(pid, P.mlkem_gen(), now)
        self.current_pqspk = pid
        self._prune(now)

    def _prune(self, now: int) -> None:
        cutoff = now - SPK_LIFETIME_S - SPK_GRACE_S
        self.spks = {k: v for k, v in self.spks.items() if v.created >= cutoff or k == self.current_spk}
        self.pqspks = {k: v for k, v in self.pqspks.items() if v.created >= cutoff or k == self.current_pqspk}

    def bundle(self) -> "PrekeyBundle":
        spk = self.spks[self.current_spk]
        pq = self.pqspks[self.current_pqspk]
        spk_pub = P.x25519_pub_bytes(spk.priv)
        pq_pub = P.mlkem_pub_bytes(pq.priv)
        return PrekeyBundle(
            ik_sig=self.identity.sig_pub,
            ik_dh=self.identity.dh_pub,
            spk_id=spk.id,
            spk=spk_pub,
            spk_sig=P.sign(self.identity.sig, P.L_SIG_SPK, struct.pack(">I", spk.id) + spk_pub + self.identity.dh_pub),
            pqspk_id=pq.id,
            pqspk=pq_pub,
            pqspk_sig=P.sign(self.identity.sig, P.L_SIG_PQSPK, struct.pack(">I", pq.id) + pq_pub),
        )

    def spk(self, sid: int, now: int | None = None) -> SignedPrekey:
        return self._lookup(self.spks, sid, now)

    def pqspk(self, pid: int, now: int | None = None) -> PQPrekey:
        return self._lookup(self.pqspks, pid, now)

    @staticmethod
    def _lookup(table, kid, now):
        now = int(time.time()) if now is None else now
        k = table.get(kid)
        if k is None or now - k.created > SPK_LIFETIME_S + SPK_GRACE_S:
            raise P.CryptoError("unknown or expired prekey")
        return k


@dataclass
class PrekeyBundle:
    ik_sig: bytes
    ik_dh: bytes
    spk_id: int
    spk: bytes
    spk_sig: bytes
    pqspk_id: int
    pqspk: bytes
    pqspk_sig: bytes

    def verify(self) -> None:
        P.verify(self.ik_sig, P.L_SIG_SPK, struct.pack(">I", self.spk_id) + self.spk + self.ik_dh, self.spk_sig)
        P.verify(self.ik_sig, P.L_SIG_PQSPK, struct.pack(">I", self.pqspk_id) + self.pqspk, self.pqspk_sig)

    def to_bytes(self) -> bytes:
        return (self.ik_sig + self.ik_dh + struct.pack(">I", self.spk_id) + self.spk + self.spk_sig
                + struct.pack(">I", self.pqspk_id) + self.pqspk + self.pqspk_sig)

    LEN = 32 + 32 + 4 + 32 + 64 + 4 + P.MLKEM768_PK_LEN + 64

    @classmethod
    def from_bytes(cls, b: bytes) -> "PrekeyBundle":
        if len(b) != cls.LEN:
            raise P.CryptoError("bad bundle length")
        o = 0

        def take(n):
            nonlocal o
            v = b[o:o + n]
            o += n
            return v
        ik_sig, ik_dh = take(32), take(32)
        spk_id = struct.unpack(">I", take(4))[0]
        spk, spk_sig = take(32), take(64)
        pq_id = struct.unpack(">I", take(4))[0]
        pq, pq_sig = take(P.MLKEM768_PK_LEN), take(64)
        return cls(ik_sig, ik_dh, spk_id, spk, spk_sig, pq_id, pq, pq_sig)


INVITE_MAGIC = b"ZWI1"


@dataclass
class Invite:
    """Out-of-band contact invite (QR or link). Carries a per-contact address."""
    address: bytes   # per-contact Unified Address (UTF-8 string bytes)
    bundle: PrekeyBundle
    invite_id: bytes  # 16 random bytes

    def to_bytes(self) -> bytes:
        if len(self.address) > 0xFFFF:
            raise P.CryptoError("address too long")
        return (INVITE_MAGIC + struct.pack(">H", len(self.address)) + self.address
                + self.bundle.to_bytes() + self.invite_id)

    @classmethod
    def from_bytes(cls, b: bytes) -> "Invite":
        if b[:4] != INVITE_MAGIC or len(b) < 6:
            raise P.CryptoError("not an invite")
        alen = struct.unpack(">H", b[4:6])[0]
        need = 6 + alen + PrekeyBundle.LEN + 16
        if len(b) != need:
            raise P.CryptoError("bad invite length")
        addr = b[6:6 + alen]
        bundle = PrekeyBundle.from_bytes(b[6 + alen:6 + alen + PrekeyBundle.LEN])
        bundle.verify()
        return cls(addr, bundle, b[-16:])
