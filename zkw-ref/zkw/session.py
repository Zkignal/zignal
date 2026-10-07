"""PQXDH-style hybrid handshake, sessions, and the inbox router (spec sections 4, 5, 9).

Wire payloads (before chunking into 512-byte memos):

HELLO   = "ZWH1" | addr_len(2) | addr | ik_sig(32) | ik_dh(32) | bind_sig(64) | hello_id(16)
BUNDLE  = Invite bytes (invite_id = the hello_id being answered)
INIT    = invite_id(16) | ek(32) | spk_id(4) | pqspk_id(4) | kem_ct(1088)
          | enc_identity(ID_PT_LEN + 16) | first ratchet message
MSG     = ratchet message (enc_header 68 | ciphertext)

enc_identity hides who is initiating from anyone holding only the recipient's
viewing key: it is sealed under HKDF(DH(EK, SPK_B) || KEM_SS).

Inside every ratchet plaintext: kind(1) | data. Receipts and reactions travel as
envelope type MSG, so an observer with a viewing key cannot tell them apart.
"""
from __future__ import annotations

import json
import struct
import time
from dataclasses import dataclass, field

from . import envelope as E
from . import primitives as P
from .identity import Identity, Invite, PrekeyBundle, PrekeyStore, verify_binding
from .ratchet import RatchetState

ADDR_FIELD = 256  # per-contact address padded to a fixed size inside enc_identity
ID_PT_LEN = 32 + 32 + 64 + 2 + ADDR_FIELD
HELLO_MAGIC = b"ZWH1"

K_TEXT = 0x01
K_RECEIPT = 0x02
K_REACTION = 0x03
K_CLOSE = 0x7F

EPOCH_S = 86400
SEEN_TTL_S = 30 * 86400


def _lp(b: bytes) -> bytes:
    return struct.pack(">H", len(b)) + b


def _ad(ik_sig_a: bytes, ik_sig_b: bytes, addr_a: bytes, addr_b: bytes) -> bytes:
    return b"zkw/ad/v1" + ik_sig_a + ik_sig_b + _lp(addr_a) + _lp(addr_b)


def _pqxdh_kdf(dh1: bytes, dh2: bytes, dh3: bytes, ss: bytes) -> tuple[bytes, bytes, bytes, bytes]:
    okm = P.hkdf(b"\xff" * 32 + dh1 + dh2 + dh3 + ss, salt=bytes(32), info=P.L_PQXDH, length=128)
    return okm[:32], okm[32:64], okm[64:96], okm[96:]  # SK, shared_hka, shared_nhkb, conv_key


def _id_key(dh3: bytes, ss: bytes) -> tuple[bytes, bytes]:
    okm = P.hkdf(dh3 + ss, salt=bytes(32), info=P.L_INIT_ID, length=44)
    return okm[:32], okm[32:]


def _pack_identity(me: Identity, addr: bytes) -> bytes:
    if len(addr) > ADDR_FIELD:
        raise P.CryptoError("address too long")
    return me.sig_pub + me.dh_pub + me.binding_sig() + struct.pack(">H", len(addr)) + addr.ljust(ADDR_FIELD, b"\0")


def _unpack_identity(b: bytes) -> tuple[bytes, bytes, bytes]:
    ik_sig, ik_dh, bind = b[:32], b[32:64], b[64:128]
    alen = struct.unpack(">H", b[128:130])[0]
    if alen > ADDR_FIELD:
        raise P.CryptoError("bad address length")
    verify_binding(ik_sig, ik_dh, bind)
    return ik_sig, ik_dh, b[130:130 + alen]


def conv_tag(conv_key: bytes, epoch: int) -> bytes:
    return P.hmac_sha256(conv_key, P.L_CONVTAG + struct.pack(">I", epoch))[:8]


@dataclass
class Session:
    peer_ik_sig: bytes
    peer_addr: bytes      # where we send to
    my_addr: bytes        # the per-contact address we gave this peer
    ad: bytes
    conv_key: bytes
    ratchet: RatchetState
    seen_msg_ids: dict[str, float] = field(default_factory=dict)

    @property
    def peer_id(self) -> str:
        return self.peer_ik_sig.hex()

    def tags(self, now: float | None = None) -> list[bytes]:
        """Tags we accept: yesterday, today, tomorrow (latency and clock skew)."""
        e = int((time.time() if now is None else now) // EPOCH_S)
        return [conv_tag(self.conv_key, x) for x in (e - 1, e, e + 1)]

    def send(self, kind: int, data: bytes, now: float | None = None) -> list[bytes]:
        e = int((time.time() if now is None else now) // EPOCH_S)
        wire = self.ratchet.encrypt(bytes([kind]) + data, self.ad)
        return E.split(E.T_MSG, conv_tag(self.conv_key, e), wire)

    def send_text(self, text: str, now: float | None = None) -> list[bytes]:
        return self.send(K_TEXT, text.encode("utf-8"), now)

    def _open(self, wire: bytes) -> tuple[int, bytes]:
        pt = self.ratchet.decrypt(wire, self.ad)
        if not pt:
            raise P.CryptoError("empty plaintext")
        return pt[0], pt[1:]

    def to_json(self) -> str:
        return json.dumps({"peer_ik_sig": self.peer_ik_sig.hex(), "peer_addr": self.peer_addr.hex(),
                           "my_addr": self.my_addr.hex(), "ad": self.ad.hex(), "conv_key": self.conv_key.hex(),
                           "ratchet": self.ratchet.to_json(), "seen": self.seen_msg_ids})

    @classmethod
    def from_json(cls, s: str) -> "Session":
        d = json.loads(s)
        return cls(bytes.fromhex(d["peer_ik_sig"]), bytes.fromhex(d["peer_addr"]), bytes.fromhex(d["my_addr"]),
                   bytes.fromhex(d["ad"]), bytes.fromhex(d["conv_key"]), RatchetState.from_json(d["ratchet"]),
                   d["seen"])


# ---------------- handshake ----------------

def initiate(me: Identity, my_addr: bytes, invite: Invite, first_text: str) -> tuple[Session, list[bytes]]:
    """Alice: run PQXDH against Bob's invite and produce the INIT memos (one transaction)."""
    b = invite.bundle
    b.verify()
    ek = P.x25519_gen()
    ek_pub = P.x25519_pub_bytes(ek)
    dh1 = P.dh(me.dh, b.spk)
    dh2 = P.dh(ek, b.ik_dh)
    dh3 = P.dh(ek, b.spk)
    kem_ct, ss = P.mlkem_encaps(b.pqspk)
    sk, hka, nhkb, conv_key = _pqxdh_kdf(dh1, dh2, dh3, ss)
    idk, idn = _id_key(dh3, ss)
    head = invite.invite_id + ek_pub + struct.pack(">II", b.spk_id, b.pqspk_id) + kem_ct
    enc_id = P.aead_seal(idk, idn, _pack_identity(me, my_addr), head)
    ad = _ad(me.sig_pub, b.ik_sig, my_addr, invite.address)
    rs = RatchetState.init_alice(sk, b.spk, hka, nhkb)
    first = rs.encrypt(bytes([K_TEXT]) + first_text.encode("utf-8"), ad)
    sess = Session(b.ik_sig, invite.address, my_addr, ad, conv_key, rs)
    return sess, E.split(E.T_INIT, P.rand(8), head + enc_id + first)


INIT_FIXED = 16 + 32 + 8 + P.MLKEM768_CT_LEN


def respond(me: Identity, store: PrekeyStore, my_addr_for: dict[bytes, bytes], payload: bytes,
            seen_eks: dict[str, float], now: float | None = None) -> tuple[Session, int, bytes]:
    """Bob: process an INIT. my_addr_for maps invite_id -> the per-contact address on that invite."""
    now = time.time() if now is None else now
    if len(payload) < INIT_FIXED + ID_PT_LEN + P.AEAD_TAG_LEN + 68 + P.AEAD_TAG_LEN:
        raise P.CryptoError("INIT too short")
    invite_id = payload[:16]
    ek_pub = payload[16:48]
    spk_id, pq_id = struct.unpack(">II", payload[48:56])
    kem_ct = payload[56:INIT_FIXED]
    enc_id = payload[INIT_FIXED:INIT_FIXED + ID_PT_LEN + P.AEAD_TAG_LEN]
    first = payload[INIT_FIXED + ID_PT_LEN + P.AEAD_TAG_LEN:]
    my_addr = my_addr_for.get(invite_id)
    if my_addr is None:
        raise P.CryptoError("unknown invite")
    if ek_pub.hex() in seen_eks:
        raise P.CryptoError("replayed INIT")
    spk = store.spk(spk_id, int(now))
    pq = store.pqspk(pq_id, int(now))
    dh3 = P.dh(spk.priv, ek_pub)
    ss = P.mlkem_decaps(pq.priv, kem_ct)
    idk, idn = _id_key(dh3, ss)
    peer_sig, peer_dh, peer_addr = _unpack_identity(P.aead_open(idk, idn, enc_id, payload[:INIT_FIXED]))
    dh1 = P.dh(spk.priv, peer_dh)
    dh2 = P.dh(me.dh, ek_pub)
    sk, hka, nhkb, conv_key = _pqxdh_kdf(dh1, dh2, dh3, ss)
    ad = _ad(peer_sig, me.sig_pub, peer_addr, my_addr)
    rs = RatchetState.init_bob(sk, spk.priv, hka, nhkb)
    sess = Session(peer_sig, peer_addr, my_addr, ad, conv_key, rs)
    kind, data = sess._open(first)
    seen_eks[ek_pub.hex()] = now  # record only after full success
    return sess, kind, data


def make_hello(me: Identity, my_addr: bytes) -> tuple[bytes, list[bytes]]:
    """Cold contact, step 1. Returns (hello_id, memos)."""
    hello_id = P.rand(16)
    payload = HELLO_MAGIC + _lp(my_addr) + me.sig_pub + me.dh_pub + me.binding_sig() + hello_id
    return hello_id, E.split(E.T_HELLO, P.rand(8), payload)


@dataclass
class ContactRequest:
    ik_sig: bytes
    ik_dh: bytes
    address: bytes
    hello_id: bytes

    @property
    def safety_peer(self) -> bytes:
        return self.ik_sig


def parse_hello(payload: bytes) -> ContactRequest:
    if payload[:4] != HELLO_MAGIC or len(payload) < 6:
        raise P.CryptoError("not a HELLO")
    alen = struct.unpack(">H", payload[4:6])[0]
    if len(payload) != 6 + alen + 32 + 32 + 64 + 16:
        raise P.CryptoError("bad HELLO length")
    o = 6 + alen
    addr = payload[6:o]
    ik_sig, ik_dh, bind, hid = payload[o:o + 32], payload[o + 32:o + 64], payload[o + 64:o + 128], payload[o + 128:]
    verify_binding(ik_sig, ik_dh, bind)
    return ContactRequest(ik_sig, ik_dh, addr, hid)


# ---------------- inbox router ----------------

@dataclass
class Event:
    kind: str                 # "message", "receipt", "reaction", "request", "bundle", "new_session", "closed"
    peer_id: str | None = None
    data: bytes = b""
    request: ContactRequest | None = None
    invite: Invite | None = None


class Inbox:
    """Owns one profile's identity, prekeys, sessions and replay state.
    Feed it every received memo (512 bytes) from the wallet's transaction history."""

    def __init__(self, identity: Identity, now: float | None = None):
        self.me = identity
        self.prekeys = PrekeyStore(identity)
        self.prekeys.rotate(int(time.time() if now is None else now))
        self.sessions: dict[str, Session] = {}
        self.invite_addrs: dict[bytes, bytes] = {}   # invite_id -> my per-contact address
        self.outgoing_hellos: dict[bytes, bytes] = {}  # hello_id -> my per-contact address
        self.requests: dict[bytes, ContactRequest] = {}
        self.seen_eks: dict[str, float] = {}
        self.reasm = E.Reassembler()

    # --- creating contacts ---
    def create_invite(self, my_addr: bytes) -> Invite:
        inv = Invite(my_addr, self.prekeys.bundle(), P.rand(16))
        self.invite_addrs[inv.invite_id] = my_addr
        return inv

    def start_from_invite(self, invite: Invite, my_addr: bytes, first_text: str) -> list[bytes]:
        sess, memos = initiate(self.me, my_addr, invite, first_text)
        self.sessions[sess.peer_id] = sess
        return memos

    def send_hello(self, my_addr: bytes) -> list[bytes]:
        hid, memos = make_hello(self.me, my_addr)
        self.outgoing_hellos[hid] = my_addr
        return memos

    def accept_request(self, hello_id: bytes, my_addr: bytes) -> tuple[bytes, list[bytes]]:
        """Bob accepts a cold HELLO. Returns (destination address, BUNDLE memos)."""
        req = self.requests.pop(hello_id)
        inv = Invite(my_addr, self.prekeys.bundle(), hello_id)
        self.invite_addrs[hello_id] = my_addr
        return req.address, E.split(E.T_BUNDLE, P.rand(8), inv.to_bytes())

    # --- receiving ---
    def receive(self, memo: bytes, now: float | None = None) -> Event | None:
        now = time.time() if now is None else now
        env = E.Envelope.decode(memo)
        if env is None:
            return None
        done = self.reasm.add(env, now)
        if done is None:
            return None
        t, tag, payload = done
        self._expire(now)
        try:
            if t == E.T_MSG:
                return self._on_msg(tag, env.msg_id, payload, now)
            if t == E.T_INIT:
                sess, kind, data = respond(self.me, self.prekeys, self.invite_addrs, payload, self.seen_eks, now)
                self.invite_addrs.pop(payload[:16], None)  # one invite = one contact
                self.sessions[sess.peer_id] = sess
                return Event("new_session", sess.peer_id, data)
            if t == E.T_HELLO:
                req = parse_hello(payload)
                self.requests[req.hello_id] = req  # never auto-accepted
                return Event("request", request=req)
            if t == E.T_BUNDLE:
                inv = Invite.from_bytes(payload)
                if inv.invite_id not in self.outgoing_hellos:
                    return None
                return Event("bundle", invite=inv)
        except (P.CryptoError, KeyError, ValueError, struct.error):
            return None  # drop silently; never tell the sender why
        return None

    def complete_hello(self, invite: Invite, first_text: str) -> list[bytes]:
        """Alice, after a BUNDLE arrives for her HELLO."""
        my_addr = self.outgoing_hellos.pop(invite.invite_id)
        return self.start_from_invite(invite, my_addr, first_text)

    def _on_msg(self, tag: bytes, msg_id: bytes, payload: bytes, now: float) -> Event | None:
        for sess in self.sessions.values():
            if tag in sess.tags(now):
                if msg_id.hex() in sess.seen_msg_ids:
                    return None
                try:
                    kind, data = sess._open(payload)
                except P.CryptoError:
                    continue  # tag collision with another conversation; keep looking
                sess.seen_msg_ids[msg_id.hex()] = now
                name = {K_TEXT: "message", K_RECEIPT: "receipt", K_REACTION: "reaction", K_CLOSE: "closed"}.get(kind)
                return Event(name, sess.peer_id, data) if name else None
        return None

    def _expire(self, now: float) -> None:
        self.seen_eks = {k: v for k, v in self.seen_eks.items() if now - v < SEEN_TTL_S}
        for s in self.sessions.values():
            s.seen_msg_ids = {k: v for k, v in s.seen_msg_ids.items() if now - v < SEEN_TTL_S}
