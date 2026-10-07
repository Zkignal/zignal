//! Hybrid PQXDH handshake, sessions, cold HELLO/BUNDLE flow, and the inbox router.
//! Wire formats are identical to the Python reference (see its session.py docstring).

use std::collections::HashMap;

use crate::envelope::{self as e, Envelope, Reassembler};
use crate::error::{fail, Error, Result};
use crate::identity::{verify_binding, Identity, Invite, PrekeyStore, Reader};
use crate::primitives as p;
use crate::ratchet::RatchetState;

pub const ADDR_FIELD: usize = 256;
pub const ID_PT_LEN: usize = 32 + 32 + 64 + 2 + ADDR_FIELD;
pub const HELLO_MAGIC: &[u8; 4] = b"ZWH1";

pub const K_TEXT: u8 = 0x01;
pub const K_RECEIPT: u8 = 0x02;
pub const K_REACTION: u8 = 0x03;
pub const K_CLOSE: u8 = 0x7F;

pub const EPOCH_S: u64 = 86_400;
pub const SEEN_TTL_S: u64 = 30 * 86_400;
pub const INIT_FIXED: usize = 16 + 32 + 8 + p::MLKEM768_CT_LEN;

fn lp(b: &[u8]) -> Vec<u8> {
    let mut v = (b.len() as u16).to_be_bytes().to_vec();
    v.extend_from_slice(b);
    v
}

fn build_ad(ik_sig_a: &[u8], ik_sig_b: &[u8], addr_a: &[u8], addr_b: &[u8]) -> Vec<u8> {
    let mut v = b"zkw/ad/v1".to_vec();
    v.extend_from_slice(ik_sig_a);
    v.extend_from_slice(ik_sig_b);
    v.extend_from_slice(&lp(addr_a));
    v.extend_from_slice(&lp(addr_b));
    v
}

/// Returns (SK, shared_hka, shared_nhkb, conv_key).
pub fn pqxdh_kdf(dh1: &[u8; 32], dh2: &[u8; 32], dh3: &[u8; 32], ss: &[u8; 32]) -> [[u8; 32]; 4] {
    let mut ikm = vec![0xFFu8; 32];
    for part in [dh1, dh2, dh3, ss] {
        ikm.extend_from_slice(part);
    }
    let okm = p::hkdf(&ikm, Some(&[0u8; 32]), p::L_PQXDH, 128);
    let mut out = [[0u8; 32]; 4];
    for (i, o) in out.iter_mut().enumerate() {
        o.copy_from_slice(&okm[i * 32..(i + 1) * 32]);
    }
    out
}

/// Returns (key, nonce) that seals the initiator identity inside INIT.
pub fn id_key(dh3: &[u8; 32], ss: &[u8; 32]) -> ([u8; 32], [u8; 12]) {
    let mut ikm = dh3.to_vec();
    ikm.extend_from_slice(ss);
    let okm = p::hkdf(&ikm, Some(&[0u8; 32]), p::L_INIT_ID, 44);
    let mut k = [0u8; 32];
    let mut n = [0u8; 12];
    k.copy_from_slice(&okm[..32]);
    n.copy_from_slice(&okm[32..]);
    (k, n)
}

pub fn conv_tag(conv_key: &[u8; 32], epoch: u32) -> [u8; 8] {
    let mut data = p::L_CONVTAG.to_vec();
    data.extend_from_slice(&epoch.to_be_bytes());
    let mac = p::hmac_sha256(conv_key, &data);
    let mut t = [0u8; 8];
    t.copy_from_slice(&mac[..8]);
    t
}

fn epoch_of(now: u64) -> u32 {
    (now / EPOCH_S) as u32
}

fn pack_identity(me: &Identity, addr: &[u8]) -> Result<Vec<u8>> {
    if addr.len() > ADDR_FIELD {
        return fail("address too long");
    }
    let mut v = me.sig_pub().to_vec();
    v.extend_from_slice(&me.dh_pub());
    v.extend_from_slice(&me.binding_sig());
    v.extend_from_slice(&(addr.len() as u16).to_be_bytes());
    v.extend_from_slice(addr);
    v.resize(ID_PT_LEN, 0);
    Ok(v)
}

fn unpack_identity(b: &[u8]) -> Result<([u8; 32], [u8; 32], Vec<u8>)> {
    let mut r = Reader::new(b);
    let ik_sig: [u8; 32] = r.arr()?;
    let ik_dh: [u8; 32] = r.arr()?;
    let bind: [u8; 64] = r.arr()?;
    let alen = u16::from_be_bytes(r.arr()?) as usize;
    if alen > ADDR_FIELD {
        return fail("bad address length");
    }
    let addr = r.take(alen)?.to_vec();
    verify_binding(&ik_sig, &ik_dh, &bind)?;
    Ok((ik_sig, ik_dh, addr))
}

pub struct Session {
    pub peer_ik_sig: [u8; 32],
    pub peer_addr: Vec<u8>,
    pub my_addr: Vec<u8>,
    ad: Vec<u8>,
    conv_key: [u8; 32],
    ratchet: RatchetState,
    seen_msg_ids: HashMap<[u8; 8], u64>,
}

impl Session {
    /// Tags we accept: yesterday, today, tomorrow (latency and clock skew).
    pub fn tags(&self, now: u64) -> [[u8; 8]; 3] {
        let e = epoch_of(now);
        [
            conv_tag(&self.conv_key, e.saturating_sub(1)),
            conv_tag(&self.conv_key, e),
            conv_tag(&self.conv_key, e + 1),
        ]
    }

    pub fn send(&mut self, kind: u8, data: &[u8], now: u64) -> Result<Vec<Vec<u8>>> {
        let mut pt = vec![kind];
        pt.extend_from_slice(data);
        let wire = self.ratchet.encrypt(&pt, &self.ad)?;
        e::split(e::T_MSG, conv_tag(&self.conv_key, epoch_of(now)), &wire)
    }

    pub fn send_text(&mut self, text: &str, now: u64) -> Result<Vec<Vec<u8>>> {
        self.send(K_TEXT, text.as_bytes(), now)
    }

    /// Decrypt one complete MSG payload. Exposed for tests (forward-secrecy check).
    pub fn open(&mut self, wire: &[u8]) -> Result<(u8, Vec<u8>)> {
        let pt = self.ratchet.decrypt(wire, &self.ad)?;
        match pt.split_first() {
            Some((k, rest)) => Ok((*k, rest.to_vec())),
            None => fail("empty plaintext"),
        }
    }

    pub fn export(&self) -> Result<String> {
        let v = serde_json::json!({
            "peer_ik_sig": hex::encode(self.peer_ik_sig),
            "peer_addr": hex::encode(&self.peer_addr),
            "my_addr": hex::encode(&self.my_addr),
            "ad": hex::encode(&self.ad),
            "conv_key": hex::encode(self.conv_key),
            "ratchet": self.ratchet.export()?,
            "seen": self.seen_msg_ids.iter().map(|(k, v)| (hex::encode(k), *v)).collect::<HashMap<_, _>>(),
        });
        Ok(v.to_string())
    }

    pub fn import(s: &str) -> Result<Self> {
        let bad = || Error::Crypto("bad session snapshot");
        let v: serde_json::Value = serde_json::from_str(s).map_err(|_| bad())?;
        let hx = |k: &str| -> Result<Vec<u8>> { hex::decode(v[k].as_str().ok_or_else(bad)?).map_err(|_| bad()) };
        let mut seen = HashMap::new();
        if let Some(m) = v["seen"].as_object() {
            for (k, t) in m {
                let id: [u8; 8] = hex::decode(k).map_err(|_| bad())?.try_into().map_err(|_| bad())?;
                seen.insert(id, t.as_u64().unwrap_or(0));
            }
        }
        Ok(Self {
            peer_ik_sig: p::to32(&hx("peer_ik_sig")?, "bad key")?,
            peer_addr: hx("peer_addr")?,
            my_addr: hx("my_addr")?,
            ad: hx("ad")?,
            conv_key: p::to32(&hx("conv_key")?, "bad key")?,
            ratchet: RatchetState::import(v["ratchet"].as_str().ok_or_else(bad)?)?,
            seen_msg_ids: seen,
        })
    }
}

// ---------------- handshake ----------------

/// Alice: run PQXDH against Bob's invite and produce the INIT memos (one transaction).
pub fn initiate(me: &Identity, my_addr: &[u8], invite: &Invite, first_text: &str) -> Result<(Session, Vec<Vec<u8>>)> {
    let b = &invite.bundle;
    b.verify()?;
    let ek = p::x25519_gen();
    let ek_pub = p::x25519_pub(&ek);
    let dh1 = p::dh(&me.dh, &b.spk)?;
    let dh2 = p::dh(&ek, &b.ik_dh)?;
    let dh3 = p::dh(&ek, &b.spk)?;
    let (kem_ct, ss) = p::mlkem_encaps(&b.pqspk)?;
    let [sk, hka, nhkb, conv_key] = pqxdh_kdf(&dh1, &dh2, &dh3, &ss);
    let (idk, idn) = id_key(&dh3, &ss);
    let mut head = invite.invite_id.to_vec();
    head.extend_from_slice(&ek_pub);
    head.extend_from_slice(&b.spk_id.to_be_bytes());
    head.extend_from_slice(&b.pqspk_id.to_be_bytes());
    head.extend_from_slice(&kem_ct);
    let enc_id = p::aead_seal(&idk, &idn, &pack_identity(me, my_addr)?, &head)?;
    let ad = build_ad(&me.sig_pub(), &b.ik_sig, my_addr, &invite.address);
    let mut rs = RatchetState::init_alice(&sk, &b.spk, &hka, &nhkb)?;
    let mut first_pt = vec![K_TEXT];
    first_pt.extend_from_slice(first_text.as_bytes());
    let first = rs.encrypt(&first_pt, &ad)?;
    let mut payload = head;
    payload.extend_from_slice(&enc_id);
    payload.extend_from_slice(&first);
    let sess = Session {
        peer_ik_sig: b.ik_sig,
        peer_addr: invite.address.clone(),
        my_addr: my_addr.to_vec(),
        ad,
        conv_key,
        ratchet: rs,
        seen_msg_ids: HashMap::new(),
    };
    Ok((sess, e::split(e::T_INIT, p::rand_array(), &payload)?))
}

/// Bob: process an INIT. Returns (session, kind, data).
pub fn respond(
    me: &Identity,
    store: &PrekeyStore,
    invite_addrs: &HashMap<[u8; 16], Vec<u8>>,
    payload: &[u8],
    seen_eks: &mut HashMap<[u8; 32], u64>,
    now: u64,
) -> Result<(Session, u8, Vec<u8>)> {
    if payload.len() < INIT_FIXED + ID_PT_LEN + p::AEAD_TAG_LEN + 68 + p::AEAD_TAG_LEN {
        return fail("INIT too short");
    }
    let mut r = Reader::new(payload);
    let invite_id: [u8; 16] = r.arr()?;
    let ek_pub: [u8; 32] = r.arr()?;
    let spk_id = r.u32()?;
    let pq_id = r.u32()?;
    let kem_ct = r.take(p::MLKEM768_CT_LEN)?;
    let enc_id = r.take(ID_PT_LEN + p::AEAD_TAG_LEN)?;
    let first = r.rest();
    let my_addr = invite_addrs
        .get(&invite_id)
        .ok_or(Error::Crypto("unknown invite"))?
        .clone();
    if seen_eks.contains_key(&ek_pub) {
        return fail("replayed INIT");
    }
    let spk = store.spk(spk_id, now)?;
    let pq = store.pqspk(pq_id, now)?;
    let dh3 = p::dh(&spk.secret, &ek_pub)?;
    let ss = p::mlkem_decaps(&pq.dk, kem_ct)?;
    let (idk, idn) = id_key(&dh3, &ss);
    let id_pt = p::aead_open(&idk, &idn, enc_id, &payload[..INIT_FIXED])?;
    let (peer_sig, peer_dh, peer_addr) = unpack_identity(&id_pt)?;
    let dh1 = p::dh(&spk.secret, &peer_dh)?;
    let dh2 = p::dh(&me.dh, &ek_pub)?;
    let [sk, hka, nhkb, conv_key] = pqxdh_kdf(&dh1, &dh2, &dh3, &ss);
    let ad = build_ad(&peer_sig, &me.sig_pub(), &peer_addr, &my_addr);
    let rs = RatchetState::init_bob(&sk, spk.secret.clone(), &hka, &nhkb);
    let mut sess = Session {
        peer_ik_sig: peer_sig,
        peer_addr,
        my_addr,
        ad,
        conv_key,
        ratchet: rs,
        seen_msg_ids: HashMap::new(),
    };
    let (kind, data) = sess.open(first)?;
    seen_eks.insert(ek_pub, now); // record only after full success
    Ok((sess, kind, data))
}

/// Cold contact, step 1. Returns (hello_id, memos).
pub fn make_hello(me: &Identity, my_addr: &[u8]) -> Result<([u8; 16], Vec<Vec<u8>>)> {
    let hello_id: [u8; 16] = p::rand_array();
    let mut payload = HELLO_MAGIC.to_vec();
    payload.extend_from_slice(&lp(my_addr));
    payload.extend_from_slice(&me.sig_pub());
    payload.extend_from_slice(&me.dh_pub());
    payload.extend_from_slice(&me.binding_sig());
    payload.extend_from_slice(&hello_id);
    Ok((hello_id, e::split(e::T_HELLO, p::rand_array(), &payload)?))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContactRequest {
    pub ik_sig: [u8; 32],
    pub ik_dh: [u8; 32],
    pub address: Vec<u8>,
    pub hello_id: [u8; 16],
}

pub fn parse_hello(payload: &[u8]) -> Result<ContactRequest> {
    if payload.len() < 6 || &payload[..4] != HELLO_MAGIC {
        return fail("not a HELLO");
    }
    let alen = u16::from_be_bytes([payload[4], payload[5]]) as usize;
    if payload.len() != 6 + alen + 32 + 32 + 64 + 16 {
        return fail("bad HELLO length");
    }
    let mut r = Reader::new(&payload[6..]);
    let address = r.take(alen)?.to_vec();
    let ik_sig: [u8; 32] = r.arr()?;
    let ik_dh: [u8; 32] = r.arr()?;
    let bind: [u8; 64] = r.arr()?;
    let hello_id: [u8; 16] = r.arr()?;
    verify_binding(&ik_sig, &ik_dh, &bind)?;
    Ok(ContactRequest {
        ik_sig,
        ik_dh,
        address,
        hello_id,
    })
}

// ---------------- inbox router ----------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    NewSession { peer: [u8; 32], data: Vec<u8> },
    Message { peer: [u8; 32], data: Vec<u8> },
    Receipt { peer: [u8; 32], data: Vec<u8> },
    Reaction { peer: [u8; 32], data: Vec<u8> },
    Closed { peer: [u8; 32] },
    Request(ContactRequest),
    Bundle(Invite),
}

/// Owns one profile's identity, prekeys, sessions and replay state.
/// Feed it every received 512-byte memo from the wallet's transaction history.
pub struct Inbox {
    pub me: Identity,
    pub prekeys: PrekeyStore,
    pub sessions: HashMap<[u8; 32], Session>,
    pub(crate) invite_addrs: HashMap<[u8; 16], Vec<u8>>,
    pub(crate) outgoing_hellos: HashMap<[u8; 16], Vec<u8>>,
    pub requests: HashMap<[u8; 16], ContactRequest>,
    pub(crate) seen_eks: HashMap<[u8; 32], u64>,
    pub(crate) reasm: Reassembler,
}

impl Inbox {
    pub fn new(identity: Identity, now: u64) -> Self {
        let mut prekeys = PrekeyStore::new(identity.clone());
        prekeys.rotate(now);
        Self {
            me: identity,
            prekeys,
            sessions: HashMap::new(),
            invite_addrs: HashMap::new(),
            outgoing_hellos: HashMap::new(),
            requests: HashMap::new(),
            seen_eks: HashMap::new(),
            reasm: Reassembler::default(),
        }
    }

    pub fn create_invite(&mut self, my_addr: &[u8]) -> Invite {
        let inv = Invite {
            address: my_addr.to_vec(),
            bundle: self.prekeys.bundle(),
            invite_id: p::rand_array(),
        };
        self.invite_addrs.insert(inv.invite_id, my_addr.to_vec());
        inv
    }

    pub fn start_from_invite(&mut self, invite: &Invite, my_addr: &[u8], first_text: &str) -> Result<Vec<Vec<u8>>> {
        let (sess, memos) = initiate(&self.me, my_addr, invite, first_text)?;
        self.sessions.insert(sess.peer_ik_sig, sess);
        Ok(memos)
    }

    pub fn send_hello(&mut self, my_addr: &[u8]) -> Result<Vec<Vec<u8>>> {
        let (hid, memos) = make_hello(&self.me, my_addr)?;
        self.outgoing_hellos.insert(hid, my_addr.to_vec());
        Ok(memos)
    }

    /// Bob accepts a cold HELLO. Returns (destination address, BUNDLE memos).
    pub fn accept_request(&mut self, hello_id: &[u8; 16], my_addr: &[u8]) -> Result<(Vec<u8>, Vec<Vec<u8>>)> {
        let req = self.requests.remove(hello_id).ok_or(Error::Crypto("no such request"))?;
        let inv = Invite {
            address: my_addr.to_vec(),
            bundle: self.prekeys.bundle(),
            invite_id: *hello_id,
        };
        self.invite_addrs.insert(*hello_id, my_addr.to_vec());
        Ok((req.address, e::split(e::T_BUNDLE, p::rand_array(), &inv.to_bytes()?)?))
    }

    /// Alice, after a BUNDLE arrives for her HELLO.
    pub fn complete_hello(&mut self, invite: &Invite, first_text: &str) -> Result<Vec<Vec<u8>>> {
        let my_addr = self
            .outgoing_hellos
            .remove(&invite.invite_id)
            .ok_or(Error::Crypto("unknown hello"))?;
        self.start_from_invite(invite, &my_addr, first_text)
    }

    /// Never returns an error to the caller: anything invalid is dropped silently.
    pub fn receive(&mut self, memo: &[u8], now: u64) -> Option<Event> {
        let env = Envelope::decode(memo)?;
        let (kind, tag, payload) = self.reasm.add(&env, now)?;
        self.expire(now);
        match kind {
            e::T_MSG => self.on_msg(&tag, &env.msg_id, &payload, now),
            e::T_INIT => {
                let (sess, _k, data) = respond(
                    &self.me,
                    &self.prekeys,
                    &self.invite_addrs,
                    &payload,
                    &mut self.seen_eks,
                    now,
                )
                .ok()?;
                let mut iid = [0u8; 16];
                iid.copy_from_slice(&payload[..16]);
                self.invite_addrs.remove(&iid); // one invite = one contact
                let peer = sess.peer_ik_sig;
                self.sessions.insert(peer, sess);
                Some(Event::NewSession { peer, data })
            }
            e::T_HELLO => {
                let req = parse_hello(&payload).ok()?;
                self.requests.insert(req.hello_id, req.clone()); // never auto-accepted
                Some(Event::Request(req))
            }
            e::T_BUNDLE => {
                let inv = Invite::from_bytes(&payload).ok()?;
                if !self.outgoing_hellos.contains_key(&inv.invite_id) {
                    return None;
                }
                Some(Event::Bundle(inv))
            }
            _ => None,
        }
    }

    fn on_msg(&mut self, tag: &[u8; 8], msg_id: &[u8; 8], payload: &[u8], now: u64) -> Option<Event> {
        for (peer, sess) in self.sessions.iter_mut() {
            if !sess.tags(now).contains(tag) {
                continue;
            }
            if sess.seen_msg_ids.contains_key(msg_id) {
                return None;
            }
            let (kind, data) = match sess.open(payload) {
                Ok(x) => x,
                Err(_) => continue, // tag collision with another conversation
            };
            sess.seen_msg_ids.insert(*msg_id, now);
            let peer = *peer;
            return match kind {
                K_TEXT => Some(Event::Message { peer, data }),
                K_RECEIPT => Some(Event::Receipt { peer, data }),
                K_REACTION => Some(Event::Reaction { peer, data }),
                K_CLOSE => Some(Event::Closed { peer }),
                _ => None,
            };
        }
        None
    }

    fn expire(&mut self, now: u64) {
        self.seen_eks.retain(|_, t| now.saturating_sub(*t) < SEEN_TTL_S);
        for s in self.sessions.values_mut() {
            s.seen_msg_ids.retain(|_, t| now.saturating_sub(*t) < SEEN_TTL_S);
        }
    }
}
