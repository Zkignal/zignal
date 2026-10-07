//! Save/restore: every flow must survive an app restart at any point.

use zkw_core::persist::{open_state, profile_keys, seal_state};
use zkw_core::session::{Event, Inbox};
use zkw_core::{Identity, Invite};

const NOW: u64 = 1_790_000_000;
const A_ADDR: &[u8] = b"utest1alice-per-contact-address";
const B_ADDR: &[u8] = b"utest1bob-per-contact-address";

fn id(c: u8) -> Identity {
    Identity::from_seed(&[c; 32]).unwrap()
}

/// Simulate an app restart: export, then import with a freshly derived identity.
fn restart(inbox: Inbox, c: u8) -> Inbox {
    let state = inbox.export().unwrap();
    drop(inbox);
    Inbox::import(id(c), &state).unwrap()
}

fn deliver(inbox: &mut Inbox, memos: &[Vec<u8>], now: u64) -> Vec<Event> {
    memos.iter().filter_map(|m| inbox.receive(m, now)).collect()
}

fn texts(evs: Vec<Event>) -> Vec<String> {
    evs.into_iter()
        .filter_map(|e| match e {
            Event::Message { data, .. } | Event::NewSession { data, .. } => Some(String::from_utf8(data).unwrap()),
            _ => None,
        })
        .collect()
}

#[test]
fn restart_both_sides_mid_conversation() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let inv = bob.create_invite(B_ADDR);
    let init = alice.start_from_invite(&inv, A_ADDR, "hi").unwrap();
    assert_eq!(texts(deliver(&mut bob, &init, NOW)), ["hi"]);
    let (ak, bk) = (alice.me.sig_pub(), bob.me.sig_pub());

    let mut alice = restart(alice, b'A');
    let mut bob = restart(bob, b'B');

    for i in 0..5 {
        let m = bob.sessions.get_mut(&ak).unwrap().send_text(&format!("b{i}"), NOW).unwrap();
        assert_eq!(texts(deliver(&mut alice, &m, NOW)), [format!("b{i}")]);
        alice = restart(alice, b'A');
        let m = alice.sessions.get_mut(&bk).unwrap().send_text(&format!("a{i}"), NOW).unwrap();
        assert_eq!(texts(deliver(&mut bob, &m, NOW)), [format!("a{i}")]);
        bob = restart(bob, b'B');
    }
}

#[test]
fn invite_created_before_restart_still_works() {
    let mut bob = Inbox::new(id(b'B'), NOW);
    let inv_bytes = bob.create_invite(B_ADDR).to_bytes().unwrap();
    let mut bob = restart(bob, b'B');
    let mut alice = Inbox::new(id(b'A'), NOW);
    let init = alice.start_from_invite(&Invite::from_bytes(&inv_bytes).unwrap(), A_ADDR, "after restart").unwrap();
    assert_eq!(texts(deliver(&mut bob, &init, NOW)), ["after restart"]);
}

#[test]
fn skipped_messages_survive_restart() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let inv = bob.create_invite(B_ADDR);
    deliver(&mut bob, &alice.start_from_invite(&inv, A_ADDR, "x").unwrap(), NOW);
    let bk = bob.me.sig_pub();
    let batch: Vec<_> = (0..4).map(|i| alice.sessions.get_mut(&bk).unwrap().send_text(&format!("m{i}"), NOW).unwrap()).collect();
    assert_eq!(texts(deliver(&mut bob, &batch[3], NOW)), ["m3"]);
    let mut bob = restart(bob, b'B');
    let mut got = Vec::new();
    for i in [1, 0, 2] {
        got.extend(texts(deliver(&mut bob, &batch[i], NOW)));
    }
    assert_eq!(got, ["m1", "m0", "m2"]);
}

#[test]
fn cold_hello_flow_with_restarts_between_every_step() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let hello = alice.send_hello(A_ADDR).unwrap();
    let mut alice = restart(alice, b'A');

    let req = match deliver(&mut bob, &hello, NOW).pop() {
        Some(Event::Request(r)) => r,
        other => panic!("expected request, got {other:?}"),
    };
    let mut bob = restart(bob, b'B');
    assert!(bob.requests.contains_key(&req.hello_id), "pending request must survive restart");

    let (_, bundle) = bob.accept_request(&req.hello_id, B_ADDR).unwrap();
    let mut bob = restart(bob, b'B');

    let inv = match deliver(&mut alice, &bundle, NOW).pop() {
        Some(Event::Bundle(i)) => i,
        other => panic!("expected bundle, got {other:?}"),
    };
    let mut alice = restart(alice, b'A');
    let init = alice.complete_hello(&inv, "cold hello").unwrap();
    assert_eq!(texts(deliver(&mut bob, &init, NOW)), ["cold hello"]);
}

#[test]
fn replays_still_rejected_after_restart() {
    let mut alice = Inbox::new(id(b'A'), NOW);
    let mut bob = Inbox::new(id(b'B'), NOW);
    let inv = bob.create_invite(B_ADDR);
    let init = alice.start_from_invite(&inv, A_ADDR, "x").unwrap();
    deliver(&mut bob, &init, NOW);
    let m = alice.sessions.get_mut(&bob.me.sig_pub()).unwrap().send_text("once", NOW).unwrap();
    assert_eq!(deliver(&mut bob, &m, NOW).len(), 1);
    let mut bob = restart(bob, b'B');
    assert!(deliver(&mut bob, &m, NOW).is_empty(), "replayed message after restart");
    assert!(deliver(&mut bob, &init, NOW).is_empty(), "replayed INIT after restart");
}

#[test]
fn wrong_identity_and_garbage_rejected() {
    let bob = Inbox::new(id(b'B'), NOW);
    let state = bob.export().unwrap();
    assert!(Inbox::import(id(b'M'), &state).is_err());
    assert!(Inbox::import(id(b'B'), "{}").is_err());
    assert!(Inbox::import(id(b'B'), "not json").is_err());
}

#[test]
fn prekey_rotation_keeps_old_invites_working() {
    let mut bob = Inbox::new(id(b'B'), NOW);
    let old_inv = bob.create_invite(B_ADDR);
    assert!(!bob.rotate_prekeys_if_due(NOW + 3600));
    let later = NOW + 8 * 86_400;
    assert!(bob.rotate_prekeys_if_due(later));
    let mut bob = restart(bob, b'B');
    let mut alice = Inbox::new(id(b'A'), later);
    let init = alice.start_from_invite(&old_inv, A_ADDR, "old invite").unwrap();
    assert_eq!(texts(deliver(&mut bob, &init, later)), ["old invite"]);
}

#[test]
fn sealed_state_and_profile_keys() {
    let (id_seed, key) = profile_keys(&[7u8; 64]).unwrap();
    let (id_seed2, key2) = profile_keys(&[7u8; 64]).unwrap();
    assert_eq!((id_seed, key), (id_seed2, key2), "deterministic");
    assert_ne!(id_seed, key, "domain separated");
    assert!(profile_keys(&[1u8; 16]).is_err());

    let bob = Inbox::new(Identity::from_seed(&id_seed).unwrap(), NOW);
    let state = bob.export().unwrap();
    let blob = seal_state(&key, state.as_bytes()).unwrap();
    assert!(!blob.windows(8).any(|w| w == &state.as_bytes()[..8]), "sealed blob must not contain clear JSON");
    assert_eq!(open_state(&key, &blob).unwrap(), state.as_bytes());
    assert!(open_state(&[9u8; 32], &blob).is_err(), "wrong key");
    let mut tampered = blob.clone();
    let n = tampered.len();
    tampered[n - 1] ^= 1;
    assert!(open_state(&key, &tampered).is_err(), "tampered");
}
