"""PIN vault (spec section 8), version 2: three PINs.

The vault holds three equal-size slots. Each PIN derives one key (Argon2id) that
opens exactly one slot:

- the unlock PIN opens the real profile,
- the duress PIN opens the decoy profile,
- the panic PIN opens the decoy profile too, after silently wiping the real
  profile's slot.

Nothing on disk says which slot is which, the slot order is random, and opening
runs Argon2id once and then tries every slot, so timing does not reveal which
PIN matched. The panic slot stores the index of the slot to wipe inside its own
encrypted contents. Wiping overwrites that slot with random bytes of the same
length, which looks identical to a real slot.

The vault stores small secrets per profile (wallet seed, message-DB key,
settings). The profile databases themselves live in separate files encrypted
under those keys; the app must keep both profiles' files at similar sizes.

Two-slot vaults from version 1 ("ZWV1") still open and wipe as before.

Limit (stated in the app): a forensic examiner may still find other traces.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

from cryptography.hazmat.primitives.kdf.argon2 import Argon2id

from . import primitives as P

MAGIC = b"ZWV2"
MAGIC_V1 = b"ZWV1"
SALT_LEN = 16
SLOT_CAPACITY = 1024  # plaintext bytes per slot (flags + length + secret + padding)
SLOT_LEN = P.AEAD_NONCE_LEN + SLOT_CAPACITY + P.AEAD_TAG_LEN
SLOTS = 3
VAULT_LEN = len(MAGIC) + SALT_LEN + SLOTS * SLOT_LEN
VAULT_V1_LEN = len(MAGIC_V1) + SALT_LEN + 2 * SLOT_LEN
FLAG_WIPE_OTHER = 0x01   # version 1 only: opening this slot wipes the other one
FLAG_WIPE_TARGET = 0x02  # version 2: opening this slot wipes the slot in bits 4 and 5


@dataclass(frozen=True)
class KdfParams:
    iterations: int = 3
    memory_kib: int = 64 * 1024  # 64 MiB
    lanes: int = 4


def _key(pin: str, salt: bytes, kp: KdfParams) -> bytes:
    return Argon2id(salt=salt, length=32, iterations=kp.iterations, lanes=kp.lanes,
                    memory_cost=kp.memory_kib, ad=P.L_VAULT).derive(pin.encode("utf-8"))


def _seal_slot(key: bytes, secret: bytes, flags: int, magic: bytes, slot_index: int) -> bytes:
    if len(secret) > SLOT_CAPACITY - 5:
        raise P.CryptoError("secret too large for slot")
    pt = bytes([flags]) + struct.pack(">I", len(secret)) + secret
    pt += P.rand(SLOT_CAPACITY - len(pt))
    nonce = P.rand(P.AEAD_NONCE_LEN)
    return nonce + P.aead_seal(key, nonce, pt, magic + bytes([slot_index]))


def _open_slot(key: bytes, slot: bytes, magic: bytes, slot_index: int) -> tuple[int, bytes] | None:
    try:
        pt = P.aead_open(key, slot[:P.AEAD_NONCE_LEN], slot[P.AEAD_NONCE_LEN:], magic + bytes([slot_index]))
    except P.CryptoError:
        return None
    n = struct.unpack(">I", pt[1:5])[0]
    if 5 + n > len(pt):
        return None
    return pt[0], pt[5:5 + n]


def _shuffled_order() -> list[int]:
    """order[slot] is the index of the entry stored in that slot."""
    order = [0, 1, 2]
    for i in range(SLOTS - 1, 0, -1):
        j = int.from_bytes(P.rand(4), "big") % (i + 1)
        order[i], order[j] = order[j], order[i]
    return order


def create(real_pin: str, real_secret: bytes, duress_pin: str, decoy_secret: bytes,
           panic_pin: str, kp: KdfParams = KdfParams()) -> bytes:
    if len({real_pin, duress_pin, panic_pin}) != 3:
        raise P.CryptoError("PINs must differ")
    salt = P.rand(SALT_LEN)
    order = _shuffled_order()
    real_slot = order.index(0)
    entries = [(real_pin, real_secret, 0),
               (duress_pin, decoy_secret, 0),
               (panic_pin, decoy_secret, FLAG_WIPE_TARGET | (real_slot << 4))]
    out = MAGIC + salt
    for slot, entry in enumerate(order):
        pin, secret, flags = entries[entry]
        out += _seal_slot(_key(pin, salt, kp), secret, flags, MAGIC, slot)
    return out


def create_v1(real_pin: str, real_secret: bytes, duress_pin: str, decoy_secret: bytes,
              wipe_real_on_duress: bool = False, kp: KdfParams = KdfParams()) -> bytes:
    """Version 1 (two slots). Kept only so tests can check that older vaults still open."""
    if real_pin == duress_pin:
        raise P.CryptoError("PINs must differ")
    salt = P.rand(SALT_LEN)
    real_first = P.rand(1)[0] & 1 == 0
    entries = [(real_pin, real_secret, 0), (duress_pin, decoy_secret, FLAG_WIPE_OTHER if wipe_real_on_duress else 0)]
    if not real_first:
        entries.reverse()
    slots = [_seal_slot(_key(pin, salt, kp), sec, fl, MAGIC_V1, i) for i, (pin, sec, fl) in enumerate(entries)]
    return MAGIC_V1 + salt + slots[0] + slots[1]


@dataclass
class Opened:
    secret: bytes
    slot: int
    wipes: int | None  # the slot this PIN silently wipes when it opens, if any


def _layout(vault: bytes) -> tuple[bytes, int]:
    if len(vault) == VAULT_LEN and vault[:4] == MAGIC:
        return MAGIC, SLOTS
    if len(vault) == VAULT_V1_LEN and vault[:4] == MAGIC_V1:
        return MAGIC_V1, 2
    raise P.CryptoError("bad vault")


def _wipe_target(magic: bytes, flags: int, slot: int, slots: int) -> int | None:
    if magic == MAGIC_V1:
        return 1 - slot if flags & FLAG_WIPE_OTHER else None
    if not flags & FLAG_WIPE_TARGET:
        return None
    target = (flags >> 4) & 0x03
    return target if target < slots and target != slot else None


def open_vault(vault: bytes, pin: str, kp: KdfParams = KdfParams()) -> Opened | None:
    """Returns the matching profile, or None for a wrong PIN. Always tries every slot."""
    magic, slots = _layout(vault)
    salt = vault[4:4 + SALT_LEN]
    key = _key(pin, salt, kp)
    base = 4 + SALT_LEN
    results = [_open_slot(key, vault[base + i * SLOT_LEN: base + (i + 1) * SLOT_LEN], magic, i)
               for i in range(slots)]
    hit = None
    for i, r in enumerate(results):
        if r is not None and hit is None:
            hit = Opened(r[1], i, _wipe_target(magic, r[0], i, slots))
    return hit


def wipe_slot(vault: bytes, slot: int) -> bytes:
    """Overwrite one slot with random bytes of identical length (looks like a valid slot)."""
    base = 4 + SALT_LEN + slot * SLOT_LEN
    return vault[:base] + P.rand(SLOT_LEN) + vault[base + SLOT_LEN:]


def unlock(vault: bytes, pin: str, kp: KdfParams = KdfParams()) -> tuple[Opened | None, bytes]:
    """App entry point: open, and apply the silent wipe if this PIN requests one.
    Returns (profile or None, vault bytes to persist)."""
    o = open_vault(vault, pin, kp)
    if o is not None and o.wipes is not None:
        vault = wipe_slot(vault, o.wipes)
    return o, vault
