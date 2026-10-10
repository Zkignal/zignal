//! Byte-for-byte compatibility with the Python reference (tests/test_vectors.json).

use serde_json::Value;
use sha2::{Digest, Sha256};
use zkw_core::envelope::{Envelope, HEADER_LEN, T_MSG};
use zkw_core::primitives as p;
use zkw_core::ratchet::{kdf_ck, kdf_rk, msg_seal};
use zkw_core::session::{conv_tag, id_key, pqxdh_kdf};
use zkw_core::{safety_number, Identity};

fn v() -> Value {
    serde_json::from_str(include_str!("test_vectors.json")).unwrap()
}

fn hx(x: &Value) -> Vec<u8> {
    hex::decode(x.as_str().unwrap()).unwrap()
}

fn h32(x: &Value) -> [u8; 32] {
    hx(x).try_into().unwrap()
}

fn seed(range: std::ops::Range<u8>) -> Vec<u8> {
    range.collect()
}

#[test]
fn identity_and_safety_number() {
    let v = v();
    let a = Identity::from_seed(&seed(0..32)).unwrap();
    let b = Identity::from_seed(&seed(32..64)).unwrap();
    let id = &v["identity"];
    assert_eq!(hex::encode(a.sig_pub()), id["a_sig_pub"].as_str().unwrap());
    assert_eq!(hex::encode(a.dh_pub()), id["a_dh_pub"].as_str().unwrap());
    assert_eq!(hex::encode(a.binding_sig()), id["a_binding_sig"].as_str().unwrap());
    assert_eq!(hex::encode(b.sig_pub()), id["b_sig_pub"].as_str().unwrap());
    assert_eq!(hex::encode(b.dh_pub()), id["b_dh_pub"].as_str().unwrap());
    assert_eq!(
        safety_number(&a.sig_pub(), &b.sig_pub()),
        id["safety_number"].as_str().unwrap()
    );
    let dh_ab = p::dh(&a.dh, &b.dh_pub()).unwrap();
    assert_eq!(hex::encode(dh_ab), v["x25519_a_b"].as_str().unwrap());
}

#[test]
fn ratchet_kdfs_and_message_seal() {
    let v = v();
    let k = &v["kdf_rk"];
    let (rk, ck, nhk) = kdf_rk(&h32(&k["rk_in"]), &h32(&k["dh_in"]));
    assert_eq!(hex::encode(rk), k["rk"].as_str().unwrap());
    assert_eq!(hex::encode(ck), k["ck"].as_str().unwrap());
    assert_eq!(hex::encode(nhk), k["nhk"].as_str().unwrap());
    let c = &v["kdf_ck"];
    let (next, mk) = kdf_ck(&h32(&c["ck_in"]));
    assert_eq!(hex::encode(next), c["ck_next"].as_str().unwrap());
    assert_eq!(hex::encode(mk), c["mk"].as_str().unwrap());
    let m = &v["msg_seal"];
    let ct = msg_seal(&h32(&m["mk"]), &hx(&m["pt"]), &hx(&m["ad"])).unwrap();
    assert_eq!(hex::encode(ct), m["ct"].as_str().unwrap());
}

#[test]
fn handshake_kdfs_and_conv_tag() {
    let v = v();
    let q = &v["pqxdh_kdf"];
    let [sk, hka, nhkb, ck] = pqxdh_kdf(&h32(&q["dh1"]), &h32(&q["dh2"]), &h32(&q["dh3"]), &h32(&q["ss"]));
    assert_eq!(hex::encode(sk), q["sk"].as_str().unwrap());
    assert_eq!(hex::encode(hka), q["shared_hka"].as_str().unwrap());
    assert_eq!(hex::encode(nhkb), q["shared_nhkb"].as_str().unwrap());
    assert_eq!(hex::encode(ck), q["conv_key"].as_str().unwrap());
    let (k, n) = id_key(&h32(&q["dh3"]), &h32(&q["ss"]));
    assert_eq!(hex::encode(k), v["init_identity_key"]["key"].as_str().unwrap());
    assert_eq!(hex::encode(n), v["init_identity_key"]["nonce"].as_str().unwrap());
    let t = &v["conv_tag"];
    let epoch = t["epoch"].as_u64().unwrap() as u32;
    assert_eq!(
        hex::encode(conv_tag(&h32(&t["conv_key"]), epoch)),
        t["tag"].as_str().unwrap()
    );
}

#[test]
fn mlkem_seed_matches_python() {
    let v = v();
    let m = &v["mlkem768_from_seed"];
    let (_dk, pk) = p::mlkem_from_seed(&hx(&m["seed"])).unwrap();
    assert_eq!(hex::encode(Sha256::digest(&pk)), m["pub_sha256"].as_str().unwrap());
}

#[test]
fn envelope_layout() {
    let v = v();
    let e = &v["envelope_zero_pad"];
    let env = Envelope {
        kind: T_MSG,
        conv_tag: [0xaa; 8],
        chunk_index: 0,
        chunk_total: 1,
        msg_id: [0xbb; 8],
        body: hx(&e["body"]),
    };
    let memo = env.encode(Some(&[0u8; 512])).unwrap();
    assert_eq!(hex::encode(&memo[..HEADER_LEN + 7]), e["memo_head"].as_str().unwrap());
    assert_eq!(hex::encode(Sha256::digest(memo)), e["memo_sha256"].as_str().unwrap());
}
