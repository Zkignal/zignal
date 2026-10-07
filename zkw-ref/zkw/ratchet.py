"""Double Ratchet with header encryption (Signal spec, "Double Ratchet with header encryption").

Header keys hide the ratchet public key and counters, so no ratchet key ever
appears in clear. State changes are transactional: a failed decrypt leaves the
session exactly as it was.

Python cannot reliably zeroize memory; the Rust/Swift ports must wipe message
keys and chain keys after use.
"""
from __future__ import annotations

import copy
import json
import struct
from collections import OrderedDict
from dataclasses import dataclass, field

from . import primitives as P

MAX_SKIP = 200          # max message keys skipped in a single step
MAX_STORED_SKIPPED = 200  # total skipped keys kept per conversation (oldest evicted)
HEADER_PT_LEN = 32 + 4 + 4
ENC_HEADER_LEN = P.AEAD_NONCE_LEN + HEADER_PT_LEN + P.AEAD_TAG_LEN  # 68
HEADER_AD = b"zkw/hdr/v1"


def kdf_rk(rk: bytes, dh_out: bytes) -> tuple[bytes, bytes, bytes]:
    okm = P.hkdf(dh_out, salt=rk, info=P.L_RK, length=96)
    return okm[:32], okm[32:64], okm[64:]  # root key, chain key, next header key


def kdf_ck(ck: bytes) -> tuple[bytes, bytes]:
    return P.hmac_sha256(ck, b"\x02"), P.hmac_sha256(ck, b"\x01")  # next chain key, message key


def msg_seal(mk: bytes, pt: bytes, ad: bytes) -> bytes:
    okm = P.hkdf(mk, salt=None, info=P.L_MSG, length=44)
    return P.aead_seal(okm[:32], okm[32:], pt, ad)


def msg_open(mk: bytes, ct: bytes, ad: bytes) -> bytes:
    okm = P.hkdf(mk, salt=None, info=P.L_MSG, length=44)
    return P.aead_open(okm[:32], okm[32:], ct, ad)


def hencrypt(hk: bytes, dh_pub: bytes, pn: int, n: int) -> bytes:
    nonce = P.rand(P.AEAD_NONCE_LEN)  # hk is reused across a chain, so the nonce must be random
    return nonce + P.aead_seal(hk, nonce, dh_pub + struct.pack(">II", pn, n), HEADER_AD)


def hdecrypt(hk: bytes | None, enc: bytes) -> tuple[bytes, int, int] | None:
    if hk is None or len(enc) != ENC_HEADER_LEN:
        return None
    try:
        pt = P.aead_open(hk, enc[:P.AEAD_NONCE_LEN], enc[P.AEAD_NONCE_LEN:], HEADER_AD)
    except P.CryptoError:
        return None
    pn, n = struct.unpack(">II", pt[32:])
    return pt[:32], pn, n


@dataclass
class RatchetState:
    dhs: object = None            # X25519PrivateKey
    dhr: bytes | None = None
    rk: bytes = b""
    cks: bytes | None = None
    ckr: bytes | None = None
    ns: int = 0
    nr: int = 0
    pn: int = 0
    hks: bytes | None = None
    hkr: bytes | None = None
    nhks: bytes | None = None
    nhkr: bytes | None = None
    skipped: "OrderedDict[tuple[bytes, int], bytes]" = field(default_factory=OrderedDict)

    # ---- initialisation (after PQXDH) ----
    @classmethod
    def init_alice(cls, sk: bytes, bob_dh_pub: bytes, shared_hka: bytes, shared_nhkb: bytes) -> "RatchetState":
        s = cls()
        s.dhs = P.x25519_gen()
        s.dhr = bob_dh_pub
        s.rk, s.cks, s.nhks = kdf_rk(sk, P.dh(s.dhs, s.dhr))
        s.hks = shared_hka
        s.nhkr = shared_nhkb
        return s

    @classmethod
    def init_bob(cls, sk: bytes, bob_dh_priv, shared_hka: bytes, shared_nhkb: bytes) -> "RatchetState":
        s = cls()
        s.dhs = bob_dh_priv
        s.rk = sk
        s.nhks = shared_nhkb
        s.nhkr = shared_hka
        return s

    # ---- encrypt ----
    def encrypt(self, pt: bytes, ad: bytes) -> bytes:
        if self.cks is None or self.hks is None:
            raise P.CryptoError("cannot send before receiving the first message")
        self.cks, mk = kdf_ck(self.cks)
        enc_header = hencrypt(self.hks, P.x25519_pub_bytes(self.dhs), self.pn, self.ns)
        self.ns += 1
        return enc_header + msg_seal(mk, pt, ad + enc_header)

    # ---- decrypt (transactional) ----
    def decrypt(self, wire: bytes, ad: bytes) -> bytes:
        if len(wire) < ENC_HEADER_LEN + P.AEAD_TAG_LEN:
            raise P.CryptoError("message too short")
        work = self._clone()
        pt = work._decrypt(wire[:ENC_HEADER_LEN], wire[ENC_HEADER_LEN:], ad)
        self.__dict__.update(work.__dict__)  # commit only on success
        return pt

    def _decrypt(self, enc_header: bytes, ct: bytes, ad: bytes) -> bytes:
        full_ad = ad + enc_header
        # 1) a previously skipped message?
        for (hk, n), mk in list(self.skipped.items()):
            h = hdecrypt(hk, enc_header)
            if h is not None and h[2] == n:
                pt = msg_open(mk, ct, full_ad)
                del self.skipped[(hk, n)]
                return pt
        # 2) current or next header key
        h = hdecrypt(self.hkr, enc_header)
        step = False
        if h is None:
            h = hdecrypt(self.nhkr, enc_header)
            step = h is not None
        if h is None:
            raise P.CryptoError("header did not decrypt")
        dh_pub, pn, n = h
        if step:
            self._skip(pn)
            self._dh_ratchet(dh_pub)
        self._skip(n)
        self.ckr, mk = kdf_ck(self.ckr)
        self.nr += 1
        return msg_open(mk, ct, full_ad)

    def _skip(self, until: int) -> None:
        if until < self.nr:
            raise P.CryptoError("replayed or duplicate message")
        if until - self.nr > MAX_SKIP:
            raise P.CryptoError("too many skipped messages")
        if self.ckr is None:
            return
        while self.nr < until:
            self.ckr, mk = kdf_ck(self.ckr)
            self.skipped[(self.hkr, self.nr)] = mk
            self.nr += 1
            while len(self.skipped) > MAX_STORED_SKIPPED:
                self.skipped.popitem(last=False)

    def _dh_ratchet(self, dh_pub: bytes) -> None:
        self.pn = self.ns
        self.ns = 0
        self.nr = 0
        self.hks = self.nhks
        self.hkr = self.nhkr
        self.dhr = dh_pub
        self.rk, self.ckr, self.nhkr = kdf_rk(self.rk, P.dh(self.dhs, self.dhr))
        self.dhs = P.x25519_gen()
        self.rk, self.cks, self.nhks = kdf_rk(self.rk, P.dh(self.dhs, self.dhr))

    def _clone(self) -> "RatchetState":
        c = copy.copy(self)
        c.skipped = OrderedDict(self.skipped)
        return c

    # ---- persistence (feed into the encrypted local store) ----
    def to_json(self) -> str:
        h = lambda b: None if b is None else b.hex()
        return json.dumps({
            "dhs": P.x25519_priv_bytes(self.dhs).hex(), "dhr": h(self.dhr), "rk": self.rk.hex(),
            "cks": h(self.cks), "ckr": h(self.ckr), "ns": self.ns, "nr": self.nr, "pn": self.pn,
            "hks": h(self.hks), "hkr": h(self.hkr), "nhks": h(self.nhks), "nhkr": h(self.nhkr),
            "skipped": [[k[0].hex(), k[1], v.hex()] for k, v in self.skipped.items()],
        })

    @classmethod
    def from_json(cls, s: str) -> "RatchetState":
        d = json.loads(s)
        u = lambda x: None if x is None else bytes.fromhex(x)
        st = cls(dhs=P.x25519_from_bytes(bytes.fromhex(d["dhs"])), dhr=u(d["dhr"]), rk=bytes.fromhex(d["rk"]),
                 cks=u(d["cks"]), ckr=u(d["ckr"]), ns=d["ns"], nr=d["nr"], pn=d["pn"],
                 hks=u(d["hks"]), hkr=u(d["hkr"]), nhks=u(d["nhks"]), nhkr=u(d["nhkr"]))
        st.skipped = OrderedDict(((bytes.fromhex(a), n), bytes.fromhex(m)) for a, n, m in d["skipped"])
        return st
