//! Identity keys, signed prekeys, safety numbers, and the QR/link invite (spec sections 3-4).

use std::collections::BTreeMap;

use ed25519_dalek::SigningKey;
use sha2::{Digest, Sha512};
use x25519_dalek::StaticSecret;

use crate::error::{fail, Result};
use crate::primitives as p;

pub const SPK_LIFETIME_S: u64 = 7 * 24 * 3600;
pub const SPK_GRACE_S: u64 = 14 * 24 * 3600;

/// Long-term messaging identity, deterministically derived from the wallet seed.
#[derive(Clone)]
pub struct Identity {
    pub sig: SigningKey,
    pub dh: StaticSecret,
}

impl Identity {
    pub fn from_seed(seed: &[u8]) -> Result<Self> {
        if seed.len() < 32 {
            return fail("seed must be at least 32 bytes");
        }
        let okm = p::hkdf(seed, Some(b"zkw"), p::L_IDENTITY, 64);
        let sig = SigningKey::from_bytes(&p::to32(&okm[..32], "seed")?);
        let dh = StaticSecret::from(p::to32(&okm[32..], "seed")?);
        Ok(Self { sig, dh })
    }

    pub fn sig_pub(&self) -> [u8; 32] {
        self.sig.verifying_key().to_bytes()
    }

    pub fn dh_pub(&self) -> [u8; 32] {
        p::x25519_pub(&self.dh)
    }

    /// Proves the X25519 identity key belongs to this Ed25519 identity.
    pub fn binding_sig(&self) -> [u8; 64] {
        p::sign(&self.sig, p::L_ID_BIND, &self.dh_pub())
    }
}

pub fn verify_binding(sig_pub: &[u8], dh_pub: &[u8], sig: &[u8]) -> Result<()> {
    p::verify(sig_pub, p::L_ID_BIND, dh_pub, sig)
}

/// 60 digits in 12 groups, identical on both devices.
pub fn safety_number(sig_pub_a: &[u8; 32], sig_pub_b: &[u8; 32]) -> String {
    let (lo, hi) = if sig_pub_a <= sig_pub_b {
        (sig_pub_a, sig_pub_b)
    } else {
        (sig_pub_b, sig_pub_a)
    };
    let mut h = Sha512::new();
    h.update(p::L_SAFETY);
    h.update(lo);
    h.update(hi);
    let d = h.finalize();
    (0..12)
        .map(|i| {
            let mut v: u64 = 0;
            for byte in &d[i * 5..i * 5 + 5] {
                v = (v << 8) | u64::from(*byte);
            }
            format!("{:05}", v % 100_000)
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub struct SignedPrekey {
    pub id: u32,
    pub secret: StaticSecret,
    pub created: u64,
}

pub struct PqPrekey {
    pub id: u32,
    pub dk: p::MlKemDk,
    pub pk: Vec<u8>,
    /// FIPS 203 seed (d || z); lets the key be persisted and re-derived.
    pub seed: [u8; 64],
    pub created: u64,
}

/// Owner side: current prekeys plus recently retired ones (kept for the grace window).
pub struct PrekeyStore {
    pub identity: Identity,
    pub spks: BTreeMap<u32, SignedPrekey>,
    pub pqspks: BTreeMap<u32, PqPrekey>,
    pub current_spk: u32,
    pub current_pqspk: u32,
    pub(crate) next_id: u32,
}

impl PrekeyStore {
    pub fn new(identity: Identity) -> Self {
        Self {
            identity,
            spks: BTreeMap::new(),
            pqspks: BTreeMap::new(),
            current_spk: 0,
            current_pqspk: 0,
            next_id: 1,
        }
    }

    pub fn rotate(&mut self, now: u64) {
        let sid = self.next_id;
        self.next_id += 1;
        self.spks.insert(
            sid,
            SignedPrekey {
                id: sid,
                secret: p::x25519_gen(),
                created: now,
            },
        );
        self.current_spk = sid;
        let pid = self.next_id;
        self.next_id += 1;
        let seed: [u8; 64] = p::rand_array();
        let (dk, pk) = p::mlkem_from_seed(&seed).expect("64-byte seed is always valid");
        self.pqspks.insert(
            pid,
            PqPrekey {
                id: pid,
                dk,
                pk,
                seed,
                created: now,
            },
        );
        self.current_pqspk = pid;
        let cutoff = now.saturating_sub(SPK_LIFETIME_S + SPK_GRACE_S);
        let (cs, cp) = (self.current_spk, self.current_pqspk);
        self.spks.retain(|k, v| v.created >= cutoff || *k == cs);
        self.pqspks.retain(|k, v| v.created >= cutoff || *k == cp);
    }

    pub fn bundle(&self) -> PrekeyBundle {
        let spk = &self.spks[&self.current_spk];
        let pq = &self.pqspks[&self.current_pqspk];
        let spk_pub = p::x25519_pub(&spk.secret);
        let ik_dh = self.identity.dh_pub();
        let mut spk_msg = spk.id.to_be_bytes().to_vec();
        spk_msg.extend_from_slice(&spk_pub);
        spk_msg.extend_from_slice(&ik_dh);
        let mut pq_msg = pq.id.to_be_bytes().to_vec();
        pq_msg.extend_from_slice(&pq.pk);
        PrekeyBundle {
            ik_sig: self.identity.sig_pub(),
            ik_dh,
            spk_id: spk.id,
            spk: spk_pub,
            spk_sig: p::sign(&self.identity.sig, p::L_SIG_SPK, &spk_msg),
            pqspk_id: pq.id,
            pqspk: pq.pk.clone(),
            pqspk_sig: p::sign(&self.identity.sig, p::L_SIG_PQSPK, &pq_msg),
        }
    }

    pub fn spk(&self, id: u32, now: u64) -> Result<&SignedPrekey> {
        match self.spks.get(&id) {
            Some(k) if now.saturating_sub(k.created) <= SPK_LIFETIME_S + SPK_GRACE_S => Ok(k),
            _ => fail("unknown or expired prekey"),
        }
    }

    pub fn pqspk(&self, id: u32, now: u64) -> Result<&PqPrekey> {
        match self.pqspks.get(&id) {
            Some(k) if now.saturating_sub(k.created) <= SPK_LIFETIME_S + SPK_GRACE_S => Ok(k),
            _ => fail("unknown or expired prekey"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrekeyBundle {
    pub ik_sig: [u8; 32],
    pub ik_dh: [u8; 32],
    pub spk_id: u32,
    pub spk: [u8; 32],
    pub spk_sig: [u8; 64],
    pub pqspk_id: u32,
    pub pqspk: Vec<u8>,
    pub pqspk_sig: [u8; 64],
}

impl PrekeyBundle {
    pub const LEN: usize = 32 + 32 + 4 + 32 + 64 + 4 + p::MLKEM768_PK_LEN + 64;

    pub fn verify(&self) -> Result<()> {
        let mut spk_msg = self.spk_id.to_be_bytes().to_vec();
        spk_msg.extend_from_slice(&self.spk);
        spk_msg.extend_from_slice(&self.ik_dh);
        p::verify(&self.ik_sig, p::L_SIG_SPK, &spk_msg, &self.spk_sig)?;
        let mut pq_msg = self.pqspk_id.to_be_bytes().to_vec();
        pq_msg.extend_from_slice(&self.pqspk);
        p::verify(&self.ik_sig, p::L_SIG_PQSPK, &pq_msg, &self.pqspk_sig)
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(Self::LEN);
        out.extend_from_slice(&self.ik_sig);
        out.extend_from_slice(&self.ik_dh);
        out.extend_from_slice(&self.spk_id.to_be_bytes());
        out.extend_from_slice(&self.spk);
        out.extend_from_slice(&self.spk_sig);
        out.extend_from_slice(&self.pqspk_id.to_be_bytes());
        out.extend_from_slice(&self.pqspk);
        out.extend_from_slice(&self.pqspk_sig);
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        if b.len() != Self::LEN {
            return fail("bad bundle length");
        }
        let mut r = Reader::new(b);
        Ok(Self {
            ik_sig: r.arr()?,
            ik_dh: r.arr()?,
            spk_id: r.u32()?,
            spk: r.arr()?,
            spk_sig: r.arr()?,
            pqspk_id: r.u32()?,
            pqspk: r.take(p::MLKEM768_PK_LEN)?.to_vec(),
            pqspk_sig: r.arr()?,
        })
    }
}

pub const INVITE_MAGIC: &[u8; 4] = b"ZWI1";

/// Out-of-band contact invite (QR or link). Carries a per-contact address.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invite {
    pub address: Vec<u8>,
    pub bundle: PrekeyBundle,
    pub invite_id: [u8; 16],
}

impl Invite {
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        if self.address.len() > 0xFFFF {
            return fail("address too long");
        }
        let mut out = INVITE_MAGIC.to_vec();
        out.extend_from_slice(&(self.address.len() as u16).to_be_bytes());
        out.extend_from_slice(&self.address);
        out.extend_from_slice(&self.bundle.to_bytes());
        out.extend_from_slice(&self.invite_id);
        Ok(out)
    }

    /// Parses and verifies the bundle signatures.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        if b.len() < 6 || &b[..4] != INVITE_MAGIC {
            return fail("not an invite");
        }
        let alen = u16::from_be_bytes([b[4], b[5]]) as usize;
        if b.len() != 6 + alen + PrekeyBundle::LEN + 16 {
            return fail("bad invite length");
        }
        let address = b[6..6 + alen].to_vec();
        let bundle = PrekeyBundle::from_bytes(&b[6 + alen..6 + alen + PrekeyBundle::LEN])?;
        bundle.verify()?;
        let mut invite_id = [0u8; 16];
        invite_id.copy_from_slice(&b[b.len() - 16..]);
        Ok(Self {
            address,
            bundle,
            invite_id,
        })
    }
}

/// Bounds-checked cursor for parsing wire formats.
pub(crate) struct Reader<'a> {
    b: &'a [u8],
    o: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(b: &'a [u8]) -> Self {
        Self { b, o: 0 }
    }

    pub(crate) fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.o + n > self.b.len() {
            return fail("truncated input");
        }
        let s = &self.b[self.o..self.o + n];
        self.o += n;
        Ok(s)
    }

    pub(crate) fn arr<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut a = [0u8; N];
        a.copy_from_slice(self.take(N)?);
        Ok(a)
    }

    pub(crate) fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.arr()?))
    }

    pub(crate) fn rest(&mut self) -> &'a [u8] {
        let s = &self.b[self.o..];
        self.o = self.b.len();
        s
    }
}
