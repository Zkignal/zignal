//! Swift-facing API for zkw-core, generated with UniFFI.
//!
//! Swift sees: `ZkwInbox` (one per profile), `ZkwEvent`, `Outgoing`, `VaultUnlock`,
//! and the free functions `vaultCreate`, `vaultUnlock`, `protocolVersion`.
//! Byte fields (`Vec<u8>`) arrive in Swift as `Data`.
//!
//! The wallet layer (ZcashLightClientKit) is responsible for actually sending
//! `Outgoing.memos` as one shielded transaction to `Outgoing.toAddress`, and for
//! feeding every received 512-byte memo into `ZkwInbox.receive`.

use std::sync::{Arc, Mutex, MutexGuard};

use zkw_core::session::{Event, Inbox, K_REACTION, K_RECEIPT, K_TEXT};
use zkw_core::vault::{self, KdfParams};
use zkw_core::{Identity, Invite};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ZkwError {
    #[error("crypto: {0}")]
    Crypto(String),
    #[error("unknown contact")]
    UnknownPeer,
    #[error("invalid input: {0}")]
    InvalidInput(String),
}

impl From<zkw_core::Error> for ZkwError {
    fn from(e: zkw_core::Error) -> Self {
        ZkwError::Crypto(e.to_string())
    }
}

/// Memos to send as ONE shielded transaction (one Orchard output per memo) to `to_address`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Outgoing {
    pub to_address: Vec<u8>,
    pub memos: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ZkwEvent {
    /// A new contact started a conversation with us (via our invite or accepted request).
    NewSession {
        peer: Vec<u8>,
        text: String,
    },
    Message {
        peer: Vec<u8>,
        text: String,
    },
    Receipt {
        peer: Vec<u8>,
        data: Vec<u8>,
    },
    Reaction {
        peer: Vec<u8>,
        reaction: String,
    },
    Closed {
        peer: Vec<u8>,
    },
    /// Someone sent a cold HELLO. Show in the Requests inbox; never auto-accept.
    Request {
        hello_id: Vec<u8>,
        peer: Vec<u8>,
        address: Vec<u8>,
    },
    /// Reply to our HELLO. Pass `invite` to `complete_hello` to start the chat.
    Bundle {
        peer: Vec<u8>,
        invite: Vec<u8>,
    },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct VaultUnlock {
    /// The profile secret for this PIN, or None for a wrong PIN.
    pub secret: Option<Vec<u8>>,
    /// Vault bytes to persist (changed only if a silent wipe ran).
    pub vault: Vec<u8>,
}

#[derive(uniffi::Object)]
pub struct ZkwInbox {
    inner: Mutex<Inbox>,
}

fn peer_key(p: &[u8]) -> Result<[u8; 32], ZkwError> {
    p.try_into()
        .map_err(|_| ZkwError::InvalidInput("peer id must be 32 bytes".into()))
}

fn text(b: Vec<u8>) -> String {
    String::from_utf8_lossy(&b).into_owned()
}

fn to_ffi(e: Event) -> ZkwEvent {
    match e {
        Event::NewSession { peer, data } => ZkwEvent::NewSession {
            peer: peer.to_vec(),
            text: text(data),
        },
        Event::Message { peer, data } => ZkwEvent::Message {
            peer: peer.to_vec(),
            text: text(data),
        },
        Event::Receipt { peer, data } => ZkwEvent::Receipt {
            peer: peer.to_vec(),
            data,
        },
        Event::Reaction { peer, data } => ZkwEvent::Reaction {
            peer: peer.to_vec(),
            reaction: text(data),
        },
        Event::Closed { peer } => ZkwEvent::Closed { peer: peer.to_vec() },
        Event::Request(r) => ZkwEvent::Request {
            hello_id: r.hello_id.to_vec(),
            peer: r.ik_sig.to_vec(),
            address: r.address,
        },
        Event::Bundle(inv) => ZkwEvent::Bundle {
            peer: inv.bundle.ik_sig.to_vec(),
            invite: inv.to_bytes().unwrap_or_default(),
        },
    }
}

impl ZkwInbox {
    fn lock(&self) -> Result<MutexGuard<'_, Inbox>, ZkwError> {
        self.inner
            .lock()
            .map_err(|_| ZkwError::Crypto("state lock poisoned".into()))
    }

    fn send_kind(&self, peer: &[u8], kind: u8, data: &[u8], now: u64) -> Result<Outgoing, ZkwError> {
        let key = peer_key(peer)?;
        let mut g = self.lock()?;
        let sess = g.sessions.get_mut(&key).ok_or(ZkwError::UnknownPeer)?;
        let memos = sess.send(kind, data, now)?;
        Ok(Outgoing {
            to_address: sess.peer_addr.clone(),
            memos,
        })
    }
}

#[uniffi::export]
impl ZkwInbox {
    /// `seed`: at least 32 bytes derived from the wallet seed. `now`: unix seconds.
    #[uniffi::constructor]
    pub fn new(seed: Vec<u8>, now: u64) -> Result<Arc<Self>, ZkwError> {
        let id = Identity::from_seed(&seed)?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Inbox::new(id, now)),
        }))
    }

    /// Our public identity (Ed25519 key, 32 bytes). Used as the contact id on the other side.
    pub fn my_id(&self) -> Result<Vec<u8>, ZkwError> {
        Ok(self.lock()?.me.sig_pub().to_vec())
    }

    /// 60-digit safety number for verifying a contact in person.
    pub fn safety_number(&self, peer: Vec<u8>) -> Result<String, ZkwError> {
        let key = peer_key(&peer)?;
        Ok(zkw_core::safety_number(&self.lock()?.me.sig_pub(), &key))
    }

    /// Contact ids we have an active session with.
    pub fn contacts(&self) -> Result<Vec<Vec<u8>>, ZkwError> {
        Ok(self.lock()?.sessions.keys().map(|k| k.to_vec()).collect())
    }

    /// Bytes to show as a QR code / link. `my_address`: a fresh per-contact Unified Address.
    pub fn create_invite(&self, my_address: Vec<u8>) -> Result<Vec<u8>, ZkwError> {
        Ok(self.lock()?.create_invite(&my_address).to_bytes()?)
    }

    /// We scanned someone's invite. Returns the INIT memos to send.
    pub fn start_from_invite(
        &self,
        invite: Vec<u8>,
        my_address: Vec<u8>,
        first_text: String,
    ) -> Result<Outgoing, ZkwError> {
        let inv = Invite::from_bytes(&invite)?;
        let memos = self.lock()?.start_from_invite(&inv, &my_address, &first_text)?;
        Ok(Outgoing {
            to_address: inv.address,
            memos,
        })
    }

    /// Cold contact: we only know their address.
    pub fn send_hello(&self, their_address: Vec<u8>, my_address: Vec<u8>) -> Result<Outgoing, ZkwError> {
        let memos = self.lock()?.send_hello(&my_address)?;
        Ok(Outgoing {
            to_address: their_address,
            memos,
        })
    }

    /// Accept a Request event. Returns the BUNDLE memos to send back.
    pub fn accept_request(&self, hello_id: Vec<u8>, my_address: Vec<u8>) -> Result<Outgoing, ZkwError> {
        let hid: [u8; 16] = hello_id
            .as_slice()
            .try_into()
            .map_err(|_| ZkwError::InvalidInput("hello id must be 16 bytes".into()))?;
        let (to_address, memos) = self.lock()?.accept_request(&hid, &my_address)?;
        Ok(Outgoing { to_address, memos })
    }

    /// After a Bundle event: start the conversation.
    pub fn complete_hello(&self, invite: Vec<u8>, first_text: String) -> Result<Outgoing, ZkwError> {
        let inv = Invite::from_bytes(&invite)?;
        let memos = self.lock()?.complete_hello(&inv, &first_text)?;
        Ok(Outgoing {
            to_address: inv.address,
            memos,
        })
    }

    pub fn send_text(&self, peer: Vec<u8>, text: String, now: u64) -> Result<Outgoing, ZkwError> {
        self.send_kind(&peer, K_TEXT, text.as_bytes(), now)
    }

    pub fn send_receipt(&self, peer: Vec<u8>, data: Vec<u8>, now: u64) -> Result<Outgoing, ZkwError> {
        self.send_kind(&peer, K_RECEIPT, &data, now)
    }

    pub fn send_reaction(&self, peer: Vec<u8>, reaction: String, now: u64) -> Result<Outgoing, ZkwError> {
        self.send_kind(&peer, K_REACTION, reaction.as_bytes(), now)
    }

    /// Feed every received 512-byte memo here. Returns an event, or None for
    /// memos that aren't ours, are incomplete chunks, or fail verification.
    pub fn receive(&self, memo: Vec<u8>, now: u64) -> Result<Option<ZkwEvent>, ZkwError> {
        Ok(self.lock()?.receive(&memo, now).map(to_ffi))
    }
}

/// Create the duress vault. Store the returned bytes; never store the PINs.
#[uniffi::export]
pub fn vault_create(
    real_pin: String,
    real_secret: Vec<u8>,
    duress_pin: String,
    decoy_secret: Vec<u8>,
    wipe_real_on_duress: bool,
) -> Result<Vec<u8>, ZkwError> {
    Ok(vault::create(
        &real_pin,
        &real_secret,
        &duress_pin,
        &decoy_secret,
        wipe_real_on_duress,
        KdfParams::default(),
    )?)
}

/// Open the vault with a PIN. Never reveals which profile (real or decoy) opened.
#[uniffi::export]
pub fn vault_unlock(vault: Vec<u8>, pin: String) -> Result<VaultUnlock, ZkwError> {
    let (opened, new_vault) = vault::unlock(&vault, &pin, KdfParams::default())?;
    Ok(VaultUnlock {
        secret: opened.map(|o| o.secret),
        vault: new_vault,
    })
}

#[uniffi::export]
pub fn protocol_version() -> String {
    zkw_core::PROTOCOL.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_790_000_000;

    #[test]
    fn swift_api_end_to_end() {
        let alice = ZkwInbox::new(vec![b'A'; 32], NOW).unwrap();
        let bob = ZkwInbox::new(vec![b'B'; 32], NOW).unwrap();
        let invite = bob.create_invite(b"utest1bob".to_vec()).unwrap();
        let out = alice
            .start_from_invite(invite, b"utest1alice".to_vec(), "hi".into())
            .unwrap();
        assert_eq!(out.to_address, b"utest1bob");
        let evs: Vec<_> = out
            .memos
            .into_iter()
            .filter_map(|m| bob.receive(m, NOW).unwrap())
            .collect();
        let alice_id = alice.my_id().unwrap();
        assert_eq!(
            evs,
            vec![ZkwEvent::NewSession {
                peer: alice_id.clone(),
                text: "hi".into()
            }]
        );

        let reply = bob.send_text(alice_id.clone(), "hey".into(), NOW).unwrap();
        assert_eq!(reply.to_address, b"utest1alice");
        let got: Vec<_> = reply
            .memos
            .into_iter()
            .filter_map(|m| alice.receive(m, NOW).unwrap())
            .collect();
        assert_eq!(
            got,
            vec![ZkwEvent::Message {
                peer: bob.my_id().unwrap(),
                text: "hey".into()
            }]
        );

        assert_eq!(
            alice.safety_number(bob.my_id().unwrap()).unwrap(),
            bob.safety_number(alice_id.clone()).unwrap()
        );
        assert!(matches!(
            alice.send_text(vec![0; 32], "x".into(), NOW),
            Err(ZkwError::UnknownPeer)
        ));
    }

    #[test]
    fn swift_api_vault() {
        let v = vault_create("2580".into(), b"REAL".to_vec(), "1111".into(), b"DECOY".to_vec(), false).unwrap();
        assert_eq!(
            vault_unlock(v.clone(), "2580".into()).unwrap().secret,
            Some(b"REAL".to_vec())
        );
        assert_eq!(
            vault_unlock(v.clone(), "1111".into()).unwrap().secret,
            Some(b"DECOY".to_vec())
        );
        assert_eq!(vault_unlock(v, "0000".into()).unwrap().secret, None);
    }
}
