"""Deterministic test vectors for the Rust/Swift ports. Run: python3 -m vectors.generate

Every value is derived from fixed inputs, so a port must reproduce each one byte for byte.
(Randomized steps such as ML-KEM encapsulation and header nonces are covered by
round-trip tests instead.)
"""
import hashlib
import json

from zkw import envelope as E
from zkw import primitives as P
from zkw.identity import Identity, safety_number
from zkw.ratchet import kdf_ck, kdf_rk, msg_seal
from zkw.session import _pqxdh_kdf, _id_key, conv_tag


def h(b: bytes) -> str:
    return b.hex()


def build() -> dict:
    a = Identity.from_seed(bytes(range(32)))
    b = Identity.from_seed(bytes(range(32, 64)))
    dh_ab = P.dh(a.dh, b.dh_pub)
    rk, ck, nhk = kdf_rk(bytes(32), dh_ab)
    ck2, mk = kdf_ck(ck)
    sk, hka, nhkb, ckey = _pqxdh_kdf(b"\x01" * 32, b"\x02" * 32, b"\x03" * 32, b"\x04" * 32)
    idk, idn = _id_key(b"\x03" * 32, b"\x04" * 32)
    kem = P.mlkem_from_seed(bytes(range(64)))
    env = E.Envelope(E.T_MSG, b"\xaa" * 8, 0, 1, b"\xbb" * 8, b"payload").encode(pad=bytes(512))
    return {
        "protocol": "zkw v0.3",
        "identity": {
            "seed_a": h(bytes(range(32))),
            "a_sig_pub": h(a.sig_pub), "a_dh_pub": h(a.dh_pub),
            "a_binding_sig": h(a.binding_sig()),
            "b_sig_pub": h(b.sig_pub), "b_dh_pub": h(b.dh_pub),
            "safety_number": safety_number(a.sig_pub, b.sig_pub),
        },
        "x25519_a_b": h(dh_ab),
        "kdf_rk": {"rk_in": h(bytes(32)), "dh_in": h(dh_ab), "rk": h(rk), "ck": h(ck), "nhk": h(nhk)},
        "kdf_ck": {"ck_in": h(ck), "ck_next": h(ck2), "mk": h(mk)},
        "msg_seal": {"mk": h(mk), "pt": h(b"hello"), "ad": h(b"ad"), "ct": h(msg_seal(mk, b"hello", b"ad"))},
        "pqxdh_kdf": {"dh1": "01" * 32, "dh2": "02" * 32, "dh3": "03" * 32, "ss": "04" * 32,
                      "sk": h(sk), "shared_hka": h(hka), "shared_nhkb": h(nhkb), "conv_key": h(ckey)},
        "init_identity_key": {"key": h(idk), "nonce": h(idn)},
        "conv_tag": {"conv_key": h(ckey), "epoch": 20717, "tag": h(conv_tag(ckey, 20717))},
        "mlkem768_from_seed": {"seed": h(bytes(range(64))),
                               "pub_sha256": hashlib.sha256(P.mlkem_pub_bytes(kem)).hexdigest()},
        "envelope_zero_pad": {"type": E.T_MSG, "conv_tag": "aa" * 8, "msg_id": "bb" * 8,
                              "body": h(b"payload"), "memo_sha256": hashlib.sha256(env).hexdigest(),
                              "memo_head": h(env[:E.HEADER_LEN + 7])},
    }


if __name__ == "__main__":
    with open("vectors/test_vectors.json", "w") as f:
        json.dump(build(), f, indent=2)
    print("wrote vectors/test_vectors.json")
