"""End-to-end and unit tests. Run: python3 -m unittest -v"""
import json
import unittest

from zkw import envelope as E
from zkw import primitives as P
from zkw import vault as V
from zkw.identity import Identity, Invite, PrekeyBundle, safety_number
from zkw.ratchet import RatchetState
from zkw.session import Inbox, Session, K_RECEIPT, K_REACTION, EPOCH_S

NOW = 1_790_000_000.0
FAST = V.KdfParams(iterations=1, memory_kib=8 * 1024, lanes=1)  # test-only; production uses defaults

A_ADDR = b"utest1alice-per-contact-address"
B_ADDR = b"utest1bob-per-contact-address"


def pair(first_text="hi bob"):
    alice = Inbox(Identity.from_seed(b"A" * 32), now=NOW)
    bob = Inbox(Identity.from_seed(b"B" * 32), now=NOW)
    invite = Invite.from_bytes(bob.create_invite(B_ADDR).to_bytes())  # through the QR codec
    init = alice.start_from_invite(invite, A_ADDR, first_text)
    evs = [bob.receive(m, NOW) for m in init]
    return alice, bob, init, [e for e in evs if e]


def deliver(inbox, memos, now=NOW):
    out = [inbox.receive(m, now) for m in memos]
    return [e for e in out if e]


class EnvelopeTests(unittest.TestCase):
    def test_roundtrip_and_fixed_size(self):
        env = E.Envelope(E.T_MSG, b"t" * 8, 0, 1, b"i" * 8, b"hello")
        memo = env.encode()
        self.assertEqual(len(memo), 512)
        self.assertEqual(memo[0], 0xFF)  # ZIP-302 arbitrary data, never parsed as text
        self.assertEqual(E.Envelope.decode(memo), env)

    def test_foreign_memos_ignored(self):
        self.assertIsNone(E.Envelope.decode(b"Thanks for lunch".ljust(512, b"\0")))
        self.assertIsNone(E.Envelope.decode(b"\xffZW" + b"\x09" + bytes(508)))  # unknown version
        self.assertIsNone(E.Envelope.decode(b"\xffXY\x02" + bytes(508)))  # someone else's binary memo
        old = bytearray(b"ZW\x01\x10" + bytes(508))  # a v0.2 memo (no 0xFF prefix)
        old[13] = 1
        self.assertIsNone(E.Envelope.decode(bytes(old)))
        self.assertIsNone(E.Envelope.decode(b"short"))

    def test_chunking_out_of_order(self):
        payload = P.rand(1500)
        memos = E.split(E.T_INIT, b"x" * 8, payload)
        self.assertEqual(len(memos), 4)
        r = E.Reassembler()
        res = [r.add(E.Envelope.decode(m), NOW) for m in reversed(memos)]
        self.assertEqual(res[-1], (E.T_INIT, b"x" * 8, payload))
        self.assertTrue(all(x is None for x in res[:-1]))

    def test_too_many_chunks(self):
        with self.assertRaises(P.CryptoError):
            E.split(E.T_MSG, b"x" * 8, bytes(E.MAX_BODY * 16))


class IdentityTests(unittest.TestCase):
    def test_deterministic_from_seed(self):
        a1, a2 = Identity.from_seed(b"s" * 32), Identity.from_seed(b"s" * 32)
        self.assertEqual((a1.sig_pub, a1.dh_pub), (a2.sig_pub, a2.dh_pub))
        self.assertNotEqual(a1.sig_pub, Identity.from_seed(b"t" * 32).sig_pub)

    def test_safety_number_symmetric(self):
        a, b = Identity.from_seed(b"a" * 32), Identity.from_seed(b"b" * 32)
        sn = safety_number(a.sig_pub, b.sig_pub)
        self.assertEqual(sn, safety_number(b.sig_pub, a.sig_pub))
        self.assertEqual(len(sn.replace(" ", "")), 60)

    def test_tampered_bundle_rejected(self):
        bob = Inbox(Identity.from_seed(b"B" * 32), now=NOW)
        raw = bytearray(bob.create_invite(B_ADDR).to_bytes())
        raw[-200] ^= 1  # flip a bit in the PQ prekey
        with self.assertRaises(P.CryptoError):
            Invite.from_bytes(bytes(raw))

    def test_identity_key_substitution_rejected(self):
        bob = Inbox(Identity.from_seed(b"B" * 32), now=NOW)
        b = bob.prekeys.bundle()
        b.ik_dh = Identity.from_seed(b"M" * 32).dh_pub  # attacker swaps the DH identity key
        with self.assertRaises(P.CryptoError):
            b.verify()


class SessionTests(unittest.TestCase):
    def test_invite_flow_and_conversation(self):
        alice, bob, init, evs = pair()
        self.assertLessEqual(len(init), 4, "INIT must fit in 4 memos (one transaction)")
        self.assertEqual(evs[0].kind, "new_session")
        self.assertEqual(evs[0].data, b"hi bob")
        b2a = bob.sessions[alice.me.sig_pub.hex()]
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        for i in range(25):  # alternating, many DH ratchet steps
            e = deliver(alice, b2a.send_text(f"b{i}", NOW))
            self.assertEqual(e[0].data, f"b{i}".encode())
            e = deliver(bob, a2b.send_text(f"a{i}", NOW))
            self.assertEqual(e[0].data, f"a{i}".encode())

    def test_max_single_memo_text(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        self.assertEqual(len(a2b.send_text("x" * 402, NOW)), 1)
        self.assertEqual(len(a2b.send_text("x" * 403, NOW)), 2)
        self.assertEqual(len(a2b.send_text("x" * 404, NOW)), 2)

    def test_long_message_chunked(self):
        alice, bob, _, _ = pair()
        text = "long " * 300
        memos = alice.sessions[bob.me.sig_pub.hex()].send_text(text, NOW)
        self.assertGreater(len(memos), 1)
        self.assertEqual(deliver(bob, memos)[0].data, text.encode())

    def test_out_of_order(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        batch = [a2b.send_text(f"m{i}", NOW) for i in range(6)]
        got = []
        for i in [3, 0, 5, 1, 4, 2]:
            got += [e.data for e in deliver(bob, batch[i])]
        self.assertEqual(sorted(got), sorted(f"m{i}".encode() for i in range(6)))

    def test_replay_rejected(self):
        alice, bob, init, _ = pair()
        memos = alice.sessions[bob.me.sig_pub.hex()].send_text("once", NOW)
        self.assertEqual(len(deliver(bob, memos)), 1)
        self.assertEqual(deliver(bob, memos), [])
        self.assertEqual(deliver(bob, init), [], "replayed INIT must be ignored")

    def test_tamper_rejected_and_state_unchanged(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        b_sess = bob.sessions[alice.me.sig_pub.hex()]
        before = b_sess.ratchet.to_json()
        memo = bytearray(a2b.send_text("secret", NOW)[0])
        good = bytes(memo)
        memo[100] ^= 0x01
        self.assertEqual(deliver(bob, [bytes(memo)]), [])
        self.assertEqual(b_sess.ratchet.to_json(), before, "failed decrypt must not change state")
        self.assertEqual(deliver(bob, [good])[0].data, b"secret")

    def test_third_party_cannot_read(self):
        alice, bob, _, _ = pair()
        eve = Inbox(Identity.from_seed(b"E" * 32), now=NOW)
        memos = alice.sessions[bob.me.sig_pub.hex()].send_text("private", NOW)
        self.assertEqual(deliver(eve, memos), [])

    def test_invite_is_single_use(self):
        alice = Inbox(Identity.from_seed(b"A" * 32), now=NOW)
        carol = Inbox(Identity.from_seed(b"C" * 32), now=NOW)
        bob = Inbox(Identity.from_seed(b"B" * 32), now=NOW)
        inv = bob.create_invite(B_ADDR)
        self.assertEqual(len(deliver(bob, alice.start_from_invite(inv, A_ADDR, "1"))), 1)
        self.assertEqual(deliver(bob, carol.start_from_invite(inv, b"utest1carol", "2")), [])

    def test_cold_hello_flow(self):
        alice = Inbox(Identity.from_seed(b"A" * 32), now=NOW)
        bob = Inbox(Identity.from_seed(b"B" * 32), now=NOW)
        ev = deliver(bob, alice.send_hello(A_ADDR))[0]
        self.assertEqual(ev.kind, "request")
        self.assertEqual(ev.request.address, A_ADDR)
        dest, bundle_memos = bob.accept_request(ev.request.hello_id, B_ADDR)
        self.assertEqual(dest, A_ADDR)
        ev2 = deliver(alice, bundle_memos)[0]
        self.assertEqual(ev2.kind, "bundle")
        ev3 = deliver(bob, alice.complete_hello(ev2.invite, "hello from cold"))[0]
        self.assertEqual((ev3.kind, ev3.data), ("new_session", b"hello from cold"))

    def test_receipts_look_like_messages(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        r = a2b.send(K_RECEIPT, b"\x00" * 8, NOW)[0]
        x = a2b.send(K_REACTION, b"+1", NOW)[0]
        self.assertEqual(E.Envelope.decode(r).type, E.T_MSG)
        self.assertEqual(E.Envelope.decode(x).type, E.T_MSG)
        kinds = [e.kind for e in deliver(bob, [r, x])]
        self.assertEqual(kinds, ["receipt", "reaction"])

    def test_persistence_midstream(self):
        alice, bob, _, _ = pair()
        pid = alice.me.sig_pub.hex()
        bob.sessions[pid] = Session.from_json(bob.sessions[pid].to_json())
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        self.assertEqual(deliver(bob, a2b.send_text("after restore", NOW))[0].data, b"after restore")

    def test_conv_tag_rotates_daily_and_accepts_skew(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        m1, m2 = a2b.send_text("d0", NOW)[0], a2b.send_text("d1", NOW + EPOCH_S)[0]
        self.assertNotEqual(m1[4:12], m2[4:12])
        self.assertEqual(len(deliver(bob, [m1, m2], NOW + EPOCH_S)), 2)

    def test_forward_secrecy(self):
        alice, bob, _, _ = pair()
        a2b = alice.sessions[bob.me.sig_pub.hex()]
        b2a = bob.sessions[alice.me.sig_pub.hex()]
        old = a2b.send_text("before compromise", NOW)
        deliver(bob, old)
        deliver(alice, b2a.send_text("reply", NOW))  # ratchet steps forward
        stolen = Session.from_json(b2a.to_json())    # attacker copies Bob's full state now
        _, payload = E.Envelope.decode(old[0]).conv_tag, E.Envelope.decode(old[0]).body
        with self.assertRaises(P.CryptoError):
            stolen._open(payload)

    def test_sender_not_in_clear(self):
        alice, bob, init, _ = pair()
        blob = b"".join(init) + b"".join(alice.sessions[bob.me.sig_pub.hex()].send_text("x", NOW))
        for secret in (alice.me.sig_pub, alice.me.dh_pub, A_ADDR):
            self.assertNotIn(secret, blob)


class VaultTests(unittest.TestCase):
    def test_real_duress_wrong(self):
        v = V.create("2580", b"REAL-SEED", "1111", b"DECOY-SEED", kp=FAST)
        self.assertEqual(V.open_vault(v, "2580", FAST).secret, b"REAL-SEED")
        self.assertEqual(V.open_vault(v, "1111", FAST).secret, b"DECOY-SEED")
        self.assertIsNone(V.open_vault(v, "0000", FAST))

    def test_layout_reveals_nothing(self):
        sizes = {len(V.create("1", b"a" * n, "2", b"b", kp=FAST)) for n in (1, 500, 900)}
        self.assertEqual(len(sizes), 1)

    def test_silent_wipe(self):
        v = V.create("2580", b"REAL", "1111", b"DECOY", wipe_real_on_duress=True, kp=FAST)
        o, v2 = V.unlock(v, "1111", FAST)
        self.assertEqual(o.secret, b"DECOY")
        self.assertEqual(len(v2), len(v))
        self.assertIsNone(V.open_vault(v2, "2580", FAST))
        self.assertEqual(V.open_vault(v2, "1111", FAST).secret, b"DECOY")

    def test_no_wipe_by_default(self):
        v = V.create("2580", b"REAL", "1111", b"DECOY", kp=FAST)
        _, v2 = V.unlock(v, "1111", FAST)
        self.assertEqual(V.open_vault(v2, "2580", FAST).secret, b"REAL")

    def test_same_pins_rejected(self):
        with self.assertRaises(P.CryptoError):
            V.create("1", b"a", "1", b"b", kp=FAST)


class VectorTests(unittest.TestCase):
    def test_vectors_match(self):
        from vectors.generate import build
        with open("vectors/test_vectors.json") as f:
            self.assertEqual(json.load(f), build())


if __name__ == "__main__":
    unittest.main()
