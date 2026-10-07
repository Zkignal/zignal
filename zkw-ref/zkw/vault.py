"""Duress PIN vault (spec section 8).

The vault holds two equal-size slots. Each PIN derives one key (Argon2id) that
opens exactly one slot. Nothing on disk says which slot is real, the slot order
is random, and opening always attempts both slots so timing does not reveal
which one matched.

The vault stores small secrets per profile (wallet seed, message-DB key,
settings). The profile databases themselves live in separate files encrypted
under those keys; the app must keep both profiles' files at similar sizes.

Silent wipe: a profile can carry an encrypted flag "wipe the other slot when I
am opened". Only the decoy should have it set. Wiping overwrites the other slot
with random bytes of the same length, which looks identical to a real slot.

Limit (stated in the app): a forensic examiner may still find other traces.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

from cryptography.hazmat.primitives.kdf.argon2 import Argon2id

from . import primitives as P

MAGIC = b"ZWV1"
SALT_LEN = 16
SLOT_CAPACITY = 1024  # plaintext bytes per slot (flags + length + secret + padding)
SLOT_LEN = P.AEAD_NONCE_LEN + SLOT_CAPACITY + P.AEAD_TAG_LEN
FLAG_WIPE_OTHER = 0x01


@dataclass(frozen=True)
class KdfParams:
    iterations: int = 3
    memory_kib: int = 64 * 1024  # 64 MiB
    lanes: int = 4


def _key(pin: str, salt: bytes, kp: KdfParams) -> bytes:
    return Argon2id(salt=salt, length=32, iterations=kp.iterations, lanes=kp.lanes,
                    memory_cost=kp.memory_kib, ad=P.L_VAULT).derive(pin.encode("utf-8"))


def _seal_slot(key: bytes, secret: bytes, flags: int, slot_index: int) -> bytes:
    if len(secret) > SLOT_CAPACITY - 5:
        raise P.CryptoError("secret too large for slot")
    pt = bytes([flags]) + struct.pack(">I", len(secret)) + secret
    pt += P.rand(SLOT_CAPACITY - len(pt))
    nonce = P.rand(P.AEAD_NONCE_LEN)
    return nonce + P.aead_seal(key, nonce, pt, MAGIC + bytes([slot_index]))


def _open_slot(key: bytes, slot: bytes, slot_index: int) -> tuple[int, bytes] | None:
    try:
        pt = P.aead_open(key, slot[:P.AEAD_NONCE_LEN], slot[P.AEAD_NONCE_LEN:], MAGIC + bytes([slot_index]))
    except P.CryptoError:
        return None
    n = struct.unpack(">I", pt[1:5])[0]
    return pt[0], pt[5:5 + n]


def create(real_pin: str, real_secret: bytes, duress_pin: str, decoy_secret: bytes,
           wipe_real_on_duress: bool = False, kp: KdfParams = KdfParams()) -> bytes:
    if real_pin == duress_pin:
        raise P.CryptoError("PINs must differ")
    salt = P.rand(SALT_LEN)
    real_first = P.rand(1)[0] & 1 == 0
    entries = [(real_pin, real_secret, 0), (duress_pin, decoy_secret, FLAG_WIPE_OTHER if wipe_real_on_duress else 0)]
    if not real_first:
        entries.reverse()
    slots = [_seal_slot(_key(pin, salt, kp), sec, fl, i) for i, (pin, sec, fl) in enumerate(entries)]
    return MAGIC + salt + slots[0] + slots[1]


@dataclass
class Opened:
    secret: bytes
    slot: int
    wipe_other: bool


def open_vault(vault: bytes, pin: str, kp: KdfParams = KdfParams()) -> Opened | None:
    """Returns the matching profile, or None for a wrong PIN. Always tries both slots."""
    if len(vault) != len(MAGIC) + SALT_LEN + 2 * SLOT_LEN or vault[:4] != MAGIC:
        raise P.CryptoError("bad vault")
    salt = vault[4:4 + SALT_LEN]
    key = _key(pin, salt, kp)
    base = 4 + SALT_LEN
    results = [_open_slot(key, vault[base + i * SLOT_LEN: base + (i + 1) * SLOT_LEN], i) for i in (0, 1)]
    hit = None
    for i, r in enumerate(results):
        if r is not None and hit is None:
            hit = Opened(r[1], i, bool(r[0] & FLAG_WIPE_OTHER))
    return hit


def wipe_slot(vault: bytes, slot: int) -> bytes:
    """Overwrite one slot with random bytes of identical length (looks like a valid slot)."""
    base = 4 + SALT_LEN + slot * SLOT_LEN
    return vault[:base] + P.rand(SLOT_LEN) + vault[base + SLOT_LEN:]


def unlock(vault: bytes, pin: str, kp: KdfParams = KdfParams()) -> tuple[Opened | None, bytes]:
    """App entry point: open, and apply the silent wipe if this profile requests it.
    Returns (profile or None, vault bytes to persist)."""
    o = open_vault(vault, pin, kp)
    if o is not None and o.wipe_other:
        vault = wipe_slot(vault, 1 - o.slot)
    return o, vault
