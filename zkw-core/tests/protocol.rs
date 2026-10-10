//! End-to-end tests, ported from the Python reference's test_protocol.py.

use zkw_core::envelope::{self as e, Envelope, Reassembler};
use zkw_core::session::{Event, Inbox, Session, EPOCH_S, K_REACTION, K_RECEIPT};
use zkw_core::vault::{self as vault, KdfParams};
use zkw_core::{safety_number, Error, Identity, Invite};

const NOW: u64 = 1_790_000_000;
const A_ADDR: &[u8] = b"utest1alice-per-contact-address";
const B_ADDR: &[u8] = b"utest1bob-per-contact-address";
const FAST: KdfParams = KdfParams {
    iterations: 1,
    memory_kib: 8 * 1024,
    lanes: 1,
};

fn id(c: u8) -> Identity {
    Identity::from_seed(&[c; 32]).unwrap()
}

fn deliver(inbox: &mut Inbox, memos: &[Vec<u8>], now: u64) -> Vec<Event> {
    memos.iter().filter_map(|m| inbox.receive(m, now)).collect()
}

/// Alice starts a session from Bob's invite (passed through the QR codec).
fn pair(first: &str) -> (Inbox, Inbox, Vec<Vec<u8>>, Vec<Event>) {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let invite = Invite::from_bytes(&bob.create_invite(B_ADDR).to_bytes().unwrap()).unwrap();
    let init = alice.start_from_invite(&invite, A_ADDR, first).unwrap();
    let evs = deliver(&mut bob, &init, NOW);
    (alice, bob, init, evs)
}

fn a2b<'a>(alice: &'a mut Inbox, bob: &Inbox) -> &'a mut Session {
    alice.sessions.get_mut(&bob.me.sig_pub()).unwrap()
}

#[test]
fn envelope_roundtrip_and_foreign_memos() {
    let env = Envelope {
        kind: e::T_MSG,
        conv_tag: *b"tttttttt",
        chunk_index: 0,
        chunk_total: 1,
        msg_id: *b"iiiiiiii",
        body: b"hello".to_vec(),
    };
    let memo = env.encode(None).unwrap();
    assert_eq!(memo.len(), 512);
    assert_eq!(memo[0], 0xFF); // ZIP-302 arbitrary data, never parsed as text
    assert_eq!(Envelope::decode(&memo), Some(env));
    let mut plain = b"Thanks for lunch".to_vec();
    plain.resize(512, 0);
    assert_eq!(Envelope::decode(&plain), None);
    assert_eq!(Envelope::decode(b"short"), None);
    let mut unknown_version = b"\xffZW\x09".to_vec();
    unknown_version.resize(512, 0);
    assert_eq!(Envelope::decode(&unknown_version), None);
    let mut other_app = b"\xffXY\x02".to_vec();
    other_app.resize(512, 0);
    assert_eq!(Envelope::decode(&other_app), None);
    let mut v02 = b"ZW\x01\x10".to_vec(); // a v0.2 memo (no 0xFF prefix)
    v02.resize(512, 0);
    v02[13] = 1;
    assert_eq!(Envelope::decode(&v02), None);
}

#[test]
fn chunking_out_of_order() {
    let payload: Vec<u8> = (0..1500u32).map(|i| (i % 251) as u8).collect();
    let memos = e::split(e::T_INIT, *b"xxxxxxxx", &payload).unwrap();
    assert_eq!(memos.len(), 4);
    let mut r = Reassembler::default();
    let mut out = None;
    for m in memos.iter().rev() {
        out = r.add(&Envelope::decode(m).unwrap(), NOW);
    }
    assert_eq!(out, Some((e::T_INIT, *b"xxxxxxxx", payload)));
    assert!(e::split(e::T_MSG, [0; 8], &vec![0u8; e::MAX_BODY * 16]).is_err());
}

#[test]
fn identity_deterministic_and_safety_symmetric() {
    assert_eq!(id(b's').sig_pub(), id(b's').sig_pub());
    assert_ne!(id(b's').sig_pub(), id(b't').sig_pub());
    let (a, b) = (id(b'a'), id(b'b'));
    let sn = safety_number(&a.sig_pub(), &b.sig_pub());
    assert_eq!(sn, safety_number(&b.sig_pub(), &a.sig_pub()));
    assert_eq!(sn.replace(' ', "").len(), 60);
}

#[test]
fn tampered_bundle_and_key_substitution_rejected() {
    let mut bob = Inbox::new(id(b'B'), NOW);
    let mut raw = bob.create_invite(B_ADDR).to_bytes().unwrap();
    let n = raw.len();
    raw[n - 200] ^= 1;
    assert!(Invite::from_bytes(&raw).is_err());
    let mut b = bob.prekeys.bundle();
    b.ik_dh = id(b'M').dh_pub();
    assert_eq!(b.verify(), Err(Error::Crypto("bad signature")));
}

#[test]
fn invite_flow_and_long_conversation() {
    let (mut alice, mut bob, init, evs) = pair("hi bob");
    assert!(init.len() <= 4, "INIT must fit in 4 memos");
    assert_eq!(
        evs,
        vec![Event::NewSession {
            peer: alice.me.sig_pub(),
            data: b"hi bob".to_vec()
        }]
    );
    let (ak, bk) = (alice.me.sig_pub(), bob.me.sig_pub());
    for i in 0..25 {
        let m = bob
            .sessions
            .get_mut(&ak)
            .unwrap()
            .send_text(&format!("b{i}"), NOW)
            .unwrap();
        assert_eq!(
            deliver(&mut alice, &m, NOW),
            vec![Event::Message {
                peer: bk,
                data: format!("b{i}").into_bytes()
            }]
        );
        let m = alice
            .sessions
            .get_mut(&bk)
            .unwrap()
            .send_text(&format!("a{i}"), NOW)
            .unwrap();
        assert_eq!(
            deliver(&mut bob, &m, NOW),
            vec![Event::Message {
                peer: ak,
                data: format!("a{i}").into_bytes()
            }]
        );
    }
}

#[test]
fn single_memo_limit_is_402_bytes() {
    let (mut alice, bob, _, _) = pair("x");
    let s = a2b(&mut alice, &bob);
    assert_eq!(s.send_text(&"x".repeat(402), NOW).unwrap().len(), 1);
    assert_eq!(s.send_text(&"x".repeat(403), NOW).unwrap().len(), 2);
}

#[test]
fn long_message_and_out_of_order() {
    let (mut alice, mut bob, _, _) = pair("x");
    let text = "long ".repeat(300);
    let memos = a2b(&mut alice, &bob).send_text(&text, NOW).unwrap();
    assert!(memos.len() > 1);
    assert!(matches!(&deliver(&mut bob, &memos, NOW)[..], [Event::Message { data, .. }] if data == text.as_bytes()));
    let batch: Vec<_> = (0..6)
        .map(|i| a2b(&mut alice, &bob).send_text(&format!("m{i}"), NOW).unwrap())
        .collect();
    let mut got = Vec::new();
    for i in [3, 0, 5, 1, 4, 2] {
        for ev in deliver(&mut bob, &batch[i], NOW) {
            if let Event::Message { data, .. } = ev {
                got.push(String::from_utf8(data).unwrap());
            }
        }
    }
    got.sort();
    assert_eq!(got, (0..6).map(|i| format!("m{i}")).collect::<Vec<_>>());
}

#[test]
fn replays_rejected() {
    let (mut alice, mut bob, init, _) = pair("x");
    let memos = a2b(&mut alice, &bob).send_text("once", NOW).unwrap();
    assert_eq!(deliver(&mut bob, &memos, NOW).len(), 1);
    assert!(deliver(&mut bob, &memos, NOW).is_empty());
    assert!(
        deliver(&mut bob, &init, NOW).is_empty(),
        "replayed INIT must be ignored"
    );
}

#[test]
fn tamper_rejected_and_state_unchanged() {
    let (mut alice, mut bob, _, _) = pair("x");
    let ak = alice.me.sig_pub();
    let before = bob.sessions[&ak].export().unwrap();
    let good = a2b(&mut alice, &bob).send_text("secret", NOW).unwrap();
    let mut bad = good.clone();
    bad[0][100] ^= 1;
    assert!(deliver(&mut bob, &bad, NOW).is_empty());
    assert_eq!(
        bob.sessions[&ak].export().unwrap(),
        before,
        "failed decrypt must not change state"
    );
    assert_eq!(deliver(&mut bob, &good, NOW).len(), 1);
}

#[test]
fn third_party_cannot_read() {
    let (mut alice, bob, _, _) = pair("x");
    let mut eve = Inbox::new(id(b'E'), NOW);
    let memos = a2b(&mut alice, &bob).send_text("private", NOW).unwrap();
    assert!(deliver(&mut eve, &memos, NOW).is_empty());
}

#[test]
fn invite_is_single_use() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut carol = Inbox::new(id(b'C'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let inv = bob.create_invite(B_ADDR);
    let m1 = alice.start_from_invite(&inv, A_ADDR, "1").unwrap();
    assert_eq!(deliver(&mut bob, &m1, NOW).len(), 1);
    let m2 = carol.start_from_invite(&inv, b"utest1carol", "2").unwrap();
    assert!(deliver(&mut bob, &m2, NOW).is_empty());
}

#[test]
fn cold_hello_flow() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let hello = alice.send_hello(A_ADDR).unwrap();
    let req = match deliver(&mut bob, &hello, NOW).pop() {
        Some(Event::Request(r)) => r,
        other => panic!("expected request, got {other:?}"),
    };
    assert_eq!(req.address, A_ADDR);
    let (dest, bundle) = bob.accept_request(&req.hello_id, B_ADDR).unwrap();
    assert_eq!(dest, A_ADDR);
    let inv = match deliver(&mut alice, &bundle, NOW).pop() {
        Some(Event::Bundle(i)) => i,
        other => panic!("expected bundle, got {other:?}"),
    };
    let init = alice.complete_hello(&inv, "hello from cold").unwrap();
    assert!(
        matches!(&deliver(&mut bob, &init, NOW)[..], [Event::NewSession { data, .. }] if data == b"hello from cold")
    );
}

#[test]
fn receipts_and_reactions_look_like_messages() {
    let (mut alice, mut bob, _, _) = pair("x");
    let r = a2b(&mut alice, &bob).send(K_RECEIPT, &[0u8; 8], NOW).unwrap();
    let x = a2b(&mut alice, &bob).send(K_REACTION, b"+1", NOW).unwrap();
    assert_eq!(Envelope::decode(&r[0]).unwrap().kind, e::T_MSG);
    assert_eq!(Envelope::decode(&x[0]).unwrap().kind, e::T_MSG);
    assert!(matches!(deliver(&mut bob, &r, NOW)[..], [Event::Receipt { .. }]));
    assert!(matches!(deliver(&mut bob, &x, NOW)[..], [Event::Reaction { .. }]));
}

#[test]
fn persistence_midstream() {
    let (mut alice, mut bob, _, _) = pair("x");
    let ak = alice.me.sig_pub();
    let restored = Session::import(&bob.sessions[&ak].export().unwrap()).unwrap();
    bob.sessions.insert(ak, restored);
    let m = a2b(&mut alice, &bob).send_text("after restore", NOW).unwrap();
    assert_eq!(deliver(&mut bob, &m, NOW).len(), 1);
}

#[test]
fn conv_tag_rotates_daily() {
    let (mut alice, mut bob, _, _) = pair("x");
    let m1 = a2b(&mut alice, &bob).send_text("d0", NOW).unwrap();
    let m2 = a2b(&mut alice, &bob).send_text("d1", NOW + EPOCH_S).unwrap();
    assert_ne!(m1[0][4..12], m2[0][4..12]);
    let both: Vec<_> = m1.into_iter().chain(m2).collect();
    assert_eq!(deliver(&mut bob, &both, NOW + EPOCH_S).len(), 2);
}

#[test]
fn forward_secrecy() {
    let (mut alice, mut bob, _, _) = pair("x");
    let (ak, bk) = (alice.me.sig_pub(), bob.me.sig_pub());
    let old = alice
        .sessions
        .get_mut(&bk)
        .unwrap()
        .send_text("before compromise", NOW)
        .unwrap();
    deliver(&mut bob, &old, NOW);
    let reply = bob.sessions.get_mut(&ak).unwrap().send_text("reply", NOW).unwrap();
    deliver(&mut alice, &reply, NOW);
    let mut stolen = Session::import(&bob.sessions[&ak].export().unwrap()).unwrap();
    let body = Envelope::decode(&old[0]).unwrap().body;
    assert!(stolen.open(&body).is_err());
}

#[test]
fn sender_not_in_clear() {
    let (mut alice, bob, init, _) = pair("x");
    let mut blob: Vec<u8> = init.concat();
    blob.extend(a2b(&mut alice, &bob).send_text("x", NOW).unwrap().concat());
    for secret in [&alice.me.sig_pub()[..], &alice.me.dh_pub()[..], A_ADDR] {
        assert!(!blob.windows(secret.len()).any(|w| w == secret));
    }
}

#[test]
fn vault_real_duress_wrong() {
    let v = vault::create("2580", b"REAL-SEED", "1111", b"DECOY-SEED", false, FAST).unwrap();
    assert_eq!(
        vault::open_vault(&v, "2580", FAST).unwrap().unwrap().secret,
        b"REAL-SEED"
    );
    assert_eq!(
        vault::open_vault(&v, "1111", FAST).unwrap().unwrap().secret,
        b"DECOY-SEED"
    );
    assert!(vault::open_vault(&v, "0000", FAST).unwrap().is_none());
    assert!(vault::create("1", b"a", "1", b"b", false, FAST).is_err());
}

#[test]
fn vault_layout_and_wipe() {
    for n in [1usize, 500, 900] {
        assert_eq!(
            vault::create("1", &vec![7u8; n], "2", b"b", false, FAST).unwrap().len(),
            vault::VAULT_LEN
        );
    }
    let v = vault::create("2580", b"REAL", "1111", b"DECOY", true, FAST).unwrap();
    let (o, v2) = vault::unlock(&v, "1111", FAST).unwrap();
    assert_eq!(o.unwrap().secret, b"DECOY");
    assert_eq!(v2.len(), v.len());
    assert!(vault::open_vault(&v2, "2580", FAST).unwrap().is_none());
    let plain = vault::create("2580", b"REAL", "1111", b"DECOY", false, FAST).unwrap();
    let (_, p2) = vault::unlock(&plain, "1111", FAST).unwrap();
    assert_eq!(vault::open_vault(&p2, "2580", FAST).unwrap().unwrap().secret, b"REAL");
}
