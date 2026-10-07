//! Save and restore an `Inbox` so chats survive an app restart.
//!
//! - The identity is NOT stored. It is re-derived from the profile secret, and
//!   `Inbox::import` refuses state that belongs to a different identity.
//! - The exported JSON contains secret keys. Always store it sealed with
//!   `seal_state` under the profile's state key; never write it to disk in clear.
//! - In-flight chunk reassembly is not saved (all chunks of one message arrive
//!   in the same transaction, so nothing is lost in practice).

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Value};
use x25519_dalek::StaticSecret;

use crate::envelope::Reassembler;
use crate::error::{Error, Result};
use crate::identity::{Identity, PqPrekey, PrekeyStore, SignedPrekey, SPK_LIFETIME_S};
use crate::primitives as p;
use crate::session::{ContactRequest, Inbox, Session};

pub const STATE_VERSION: u64 = 1;

fn bad() -> Error {
    Error::Crypto("bad saved state")
}

fn hx(v: &Value) -> Result<Vec<u8>> {
    hex::decode(v.as_str().ok_or_else(bad)?).map_err(|_| bad())
}

fn arr<const N: usize>(v: &Value) -> Result<[u8; N]> {
    hx(v)?.try_into().map_err(|_| bad())
}

fn num(v: &Value) -> Result<u64> {
    v.as_u64().ok_or_else(bad)
}

fn id32(v: &Value) -> Result<u32> {
    u32::try_from(num(v)?).map_err(|_| bad())
}

fn list(v: &Value) -> Result<&Vec<Value>> {
    v.as_array().ok_or_else(bad)
}

fn pairs16(v: &Value) -> Result<HashMap<[u8; 16], Vec<u8>>> {
    let mut m = HashMap::new();
    for e in list(v)? {
        m.insert(arr::<16>(&e[0])?, hx(&e[1])?);
    }
    Ok(m)
}

/// Split one profile secret (e.g. the wallet seed held in the duress vault) into
/// (messaging identity seed, local state key). Domain-separated, so neither reveals the other.
pub fn profile_keys(profile_secret: &[u8]) -> Result<([u8; 32], [u8; 32])> {
    if profile_secret.len() < 32 {
        return Err(Error::Crypto("profile secret must be at least 32 bytes"));
    }
    let id = p::to32(&p::hkdf(profile_secret, Some(b"zkw"), p::L_PROFILE_ID, 32), "kdf")?;
    let st = p::to32(&p::hkdf(profile_secret, Some(b"zkw"), p::L_PROFILE_STATE, 32), "kdf")?;
    Ok((id, st))
}

/// Encrypt exported state for storage: nonce(12) || ChaCha20-Poly1305 ciphertext.
pub fn seal_state(state_key: &[u8; 32], state: &[u8]) -> Result<Vec<u8>> {
    let nonce: [u8; 12] = p::rand_array();
    let mut out = nonce.to_vec();
    out.extend_from_slice(&p::aead_seal(state_key, &nonce, state, p::L_STATE)?);
    Ok(out)
}

pub fn open_state(state_key: &[u8; 32], blob: &[u8]) -> Result<Vec<u8>> {
    if blob.len() < p::AEAD_NONCE_LEN + p::AEAD_TAG_LEN {
        return Err(bad());
    }
    p::aead_open(state_key, &blob[..12], &blob[12..], p::L_STATE)
}

impl Inbox {
    /// Serialize everything needed to resume: prekeys, sessions, pending invites,
    /// pending contact requests, and replay-protection state. Contains secrets.
    pub fn export(&self) -> Result<String> {
        let pk = &self.prekeys;
        let mut sessions = Vec::with_capacity(self.sessions.len());
        for s in self.sessions.values() {
            sessions.push(Value::String(s.export()?));
        }
        let v = json!({
            "v": STATE_VERSION,
            "id": hex::encode(self.me.sig_pub()),
            "prekeys": {
                "next_id": pk.next_id,
                "current_spk": pk.current_spk,
                "current_pqspk": pk.current_pqspk,
                "spks": pk.spks.values().map(|k| json!({
                    "id": k.id, "secret": hex::encode(k.secret.to_bytes()), "created": k.created,
                })).collect::<Vec<_>>(),
                "pqspks": pk.pqspks.values().map(|k| json!({
                    "id": k.id, "seed": hex::encode(k.seed), "created": k.created,
                })).collect::<Vec<_>>(),
            },
            "sessions": sessions,
            "invite_addrs": self.invite_addrs.iter()
                .map(|(k, a)| json!([hex::encode(k), hex::encode(a)])).collect::<Vec<_>>(),
            "outgoing_hellos": self.outgoing_hellos.iter()
                .map(|(k, a)| json!([hex::encode(k), hex::encode(a)])).collect::<Vec<_>>(),
            "requests": self.requests.values().map(|r| json!({
                "ik_sig": hex::encode(r.ik_sig), "ik_dh": hex::encode(r.ik_dh),
                "address": hex::encode(&r.address), "hello_id": hex::encode(r.hello_id),
            })).collect::<Vec<_>>(),
            "seen_eks": self.seen_eks.iter()
                .map(|(k, t)| json!([hex::encode(k), t])).collect::<Vec<_>>(),
        });
        Ok(v.to_string())
    }

    /// Rebuild an inbox from `export()` output. Fails if the state was made by a different identity.
    pub fn import(identity: Identity, state: &str) -> Result<Self> {
        let v: Value = serde_json::from_str(state).map_err(|_| bad())?;
        if num(&v["v"])? != STATE_VERSION {
            return Err(Error::Crypto("unsupported saved state version"));
        }
        if hx(&v["id"])? != identity.sig_pub() {
            return Err(Error::Crypto("saved state belongs to a different identity"));
        }

        let pv = &v["prekeys"];
        let mut spks = BTreeMap::new();
        for k in list(&pv["spks"])? {
            let id = id32(&k["id"])?;
            let secret = StaticSecret::from(arr::<32>(&k["secret"])?);
            spks.insert(id, SignedPrekey { id, secret, created: num(&k["created"])? });
        }
        let mut pqspks = BTreeMap::new();
        for k in list(&pv["pqspks"])? {
            let id = id32(&k["id"])?;
            let seed = arr::<64>(&k["seed"])?;
            let (dk, pk) = p::mlkem_from_seed(&seed)?;
            pqspks.insert(id, PqPrekey { id, dk, pk, seed, created: num(&k["created"])? });
        }
        let prekeys = PrekeyStore {
            identity: identity.clone(),
            spks,
            pqspks,
            current_spk: id32(&pv["current_spk"])?,
            current_pqspk: id32(&pv["current_pqspk"])?,
            next_id: id32(&pv["next_id"])?,
        };
        if !prekeys.spks.contains_key(&prekeys.current_spk) || !prekeys.pqspks.contains_key(&prekeys.current_pqspk) {
            return Err(bad());
        }

        let mut sessions = HashMap::new();
        for s in list(&v["sessions"])? {
            let sess = Session::import(s.as_str().ok_or_else(bad)?)?;
            sessions.insert(sess.peer_ik_sig, sess);
        }
        let mut requests = HashMap::new();
        for r in list(&v["requests"])? {
            let req = ContactRequest {
                ik_sig: arr(&r["ik_sig"])?,
                ik_dh: arr(&r["ik_dh"])?,
                address: hx(&r["address"])?,
                hello_id: arr(&r["hello_id"])?,
            };
            requests.insert(req.hello_id, req);
        }
        let mut seen_eks = HashMap::new();
        for e in list(&v["seen_eks"])? {
            seen_eks.insert(arr::<32>(&e[0])?, num(&e[1])?);
        }

        Ok(Inbox {
            me: identity,
            prekeys,
            sessions,
            invite_addrs: pairs16(&v["invite_addrs"])?,
            outgoing_hellos: pairs16(&v["outgoing_hellos"])?,
            requests,
            seen_eks,
            reasm: Reassembler::default(),
        })
    }

    /// Rotate signed prekeys once they are a week old. Old ones stay valid through
    /// the grace window, so invites already handed out keep working. Returns true if rotated.
    pub fn rotate_prekeys_if_due(&mut self, now: u64) -> bool {
        let created = self.prekeys.spks.get(&self.prekeys.current_spk).map(|k| k.created).unwrap_or(0);
        if now.saturating_sub(created) >= SPK_LIFETIME_S {
            self.prekeys.rotate(now);
            true
        } else {
            false
        }
    }
}
