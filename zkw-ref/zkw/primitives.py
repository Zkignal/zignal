"""Thin wrappers over vetted primitives (pyca/cryptography). No homegrown crypto here.

Every KDF use carries its own info label (domain separation). Labels are the
single source of truth for the Rust/Swift ports; keep them byte-identical.
"""
from __future__ import annotations

import hmac as _hmac
import hashlib
import os

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.asymmetric.mlkem import MLKEM768PrivateKey, MLKEM768PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.exceptions import InvalidSignature, InvalidTag

# ---- domain-separation labels (protocol constants) ----
L_IDENTITY = b"zkw/identity/v1"
L_PQXDH = b"zkw/pqxdh/v1"
L_INIT_ID = b"zkw/init-identity/v1"
L_RK = b"zkw/ratchet/rk/v1"
L_MSG = b"zkw/ratchet/msg/v1"
L_CONVTAG = b"zkw/convtag/v1"
L_SIG_SPK = b"zkw/sig/spk/v1"
L_SIG_PQSPK = b"zkw/sig/pqspk/v1"
L_SAFETY = b"zkw/safety/v1"
L_VAULT = b"zkw/vault/v1"
L_ID_BIND = b"zkw/sig/id-bind/v1"

X25519_LEN = 32
ED25519_SIG_LEN = 64
MLKEM768_PK_LEN = 1184
MLKEM768_CT_LEN = 1088
AEAD_TAG_LEN = 16
AEAD_NONCE_LEN = 12


class CryptoError(Exception):
    """Any authentication or validation failure. Callers must not distinguish subtypes to peers."""


def rand(n: int) -> bytes:
    return os.urandom(n)


def hkdf(ikm: bytes, *, salt: bytes | None, info: bytes, length: int) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return _hmac.new(key, data, hashlib.sha256).digest()


def ct_eq(a: bytes, b: bytes) -> bool:
    return _hmac.compare_digest(a, b)


# ---- X25519 ----
def x25519_gen() -> X25519PrivateKey:
    return X25519PrivateKey.generate()


def x25519_from_bytes(b: bytes) -> X25519PrivateKey:
    _req_len(b, X25519_LEN, "x25519 private key")
    return X25519PrivateKey.from_private_bytes(b)


def x25519_pub(b: bytes) -> X25519PublicKey:
    _req_len(b, X25519_LEN, "x25519 public key")
    return X25519PublicKey.from_public_bytes(b)


def x25519_pub_bytes(k: X25519PrivateKey) -> bytes:
    return k.public_key().public_bytes_raw()


def x25519_priv_bytes(k: X25519PrivateKey) -> bytes:
    return k.private_bytes_raw()


def dh(priv: X25519PrivateKey, pub: bytes) -> bytes:
    out = priv.exchange(x25519_pub(pub))
    # Reject all-zero output (small-order point), per RFC 7748 section 6.1.
    if out == bytes(32):
        raise CryptoError("invalid DH output")
    return out


# ---- Ed25519 ----
def ed25519_from_seed(seed32: bytes) -> Ed25519PrivateKey:
    _req_len(seed32, 32, "ed25519 seed")
    return Ed25519PrivateKey.from_private_bytes(seed32)


def ed25519_pub_bytes(k: Ed25519PrivateKey) -> bytes:
    return k.public_key().public_bytes_raw()


def sign(k: Ed25519PrivateKey, label: bytes, msg: bytes) -> bytes:
    return k.sign(label + msg)


def verify(pub: bytes, label: bytes, msg: bytes, sig: bytes) -> None:
    _req_len(pub, 32, "ed25519 public key")
    _req_len(sig, ED25519_SIG_LEN, "ed25519 signature")
    try:
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, label + msg)
    except InvalidSignature as e:
        raise CryptoError("bad signature") from e


# ---- ML-KEM-768 (FIPS 203) ----
def mlkem_gen() -> MLKEM768PrivateKey:
    return MLKEM768PrivateKey.generate()


def mlkem_from_seed(seed64: bytes) -> MLKEM768PrivateKey:
    _req_len(seed64, 64, "ml-kem seed")
    return MLKEM768PrivateKey.from_seed_bytes(seed64)


def mlkem_pub_bytes(k: MLKEM768PrivateKey) -> bytes:
    return k.public_key().public_bytes_raw()


def mlkem_encaps(pub: bytes) -> tuple[bytes, bytes]:
    """Returns (ciphertext, shared_secret)."""
    _req_len(pub, MLKEM768_PK_LEN, "ml-kem public key")
    ss, ct = MLKEM768PublicKey.from_public_bytes(pub).encapsulate()
    return ct, ss


def mlkem_decaps(k: MLKEM768PrivateKey, ct: bytes) -> bytes:
    _req_len(ct, MLKEM768_CT_LEN, "ml-kem ciphertext")
    return k.decapsulate(ct)


# ---- AEAD: ChaCha20-Poly1305 (decision for v0.2: fixed) ----
def aead_seal(key: bytes, nonce: bytes, pt: bytes, ad: bytes) -> bytes:
    _req_len(key, 32, "aead key")
    _req_len(nonce, AEAD_NONCE_LEN, "aead nonce")
    return ChaCha20Poly1305(key).encrypt(nonce, pt, ad)


def aead_open(key: bytes, nonce: bytes, ct: bytes, ad: bytes) -> bytes:
    _req_len(key, 32, "aead key")
    _req_len(nonce, AEAD_NONCE_LEN, "aead nonce")
    if len(ct) < AEAD_TAG_LEN:
        raise CryptoError("ciphertext too short")
    try:
        return ChaCha20Poly1305(key).decrypt(nonce, ct, ad)
    except InvalidTag as e:
        raise CryptoError("authentication failed") from e


def _req_len(b: bytes, n: int, what: str) -> None:
    if not isinstance(b, (bytes, bytearray)) or len(b) != n:
        raise CryptoError(f"{what} must be {n} bytes")
