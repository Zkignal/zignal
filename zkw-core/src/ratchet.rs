//! Double Ratchet with header encryption (Signal spec). Decrypt is transactional:
//! a failed decrypt leaves the state exactly as it was. Secrets are zeroized on drop
//! (StaticSecret and the Zeroize derive below).

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};
use x25519_dalek::StaticSecret;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::error::{fail, Error, Result};
use crate::primitives as p;

pub const MAX_SKIP: u32 = 200;
pub const MAX_STORED_SKIPPED: usize = 200;
pub const HEADER_PT_LEN: usize = 32 + 4 + 4;
pub const ENC_HEADER_LEN: usize = p::AEAD_NONCE_LEN + HEADER_PT_LEN + p::AEAD_TAG_LEN; // 68
pub const HEADER_AD: &[u8] = b"zkw/hdr/v1";

/// Returns (root key, chain key, next header key).
pub fn kdf_rk(rk: &[u8; 32], dh_out: &[u8; 32]) -> ([u8; 32], [u8; 32], [u8; 32]) {
    let okm = p::hkdf(dh_out, Some(rk), p::L_RK, 96);
    let mut a = [0u8; 32];
    let mut b = [0u8; 32];
    let mut c = [0u8; 32];
    a.copy_from_slice(&okm[..32]);
    b.copy_from_slice(&okm[32..64]);
    c.copy_from_slice(&okm[64..]);
    (a, b, c)
}

/// Returns (next chain key, message key).
pub fn kdf_ck(ck: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    (p::hmac_sha256(ck, &[0x02]), p::hmac_sha256(ck, &[0x01]))
}

fn msg_keys(mk: &[u8; 32]) -> Vec<u8> {
    p::hkdf(mk, None, p::L_MSG, 44)
}

pub fn msg_seal(mk: &[u8; 32], pt: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
    let mut k = msg_keys(mk);
    let r = p::aead_seal(&k[..32], &k[32..], pt, ad);
    k.zeroize();
    r
}

pub fn msg_open(mk: &[u8; 32], ct: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
    let mut k = msg_keys(mk);
    let r = p::aead_open(&k[..32], &k[32..], ct, ad);
    k.zeroize();
    r
}

fn hencrypt(hk: &[u8; 32], dh_pub: &[u8; 32], pn: u32, n: u32) -> Result<Vec<u8>> {
    let nonce: [u8; 12] = p::rand_array(); // hk is reused across a chain, so the nonce must be random
    let mut pt = dh_pub.to_vec();
    pt.extend_from_slice(&pn.to_be_bytes());
    pt.extend_from_slice(&n.to_be_bytes());
    let mut out = nonce.to_vec();
    out.extend_from_slice(&p::aead_seal(hk, &nonce, &pt, HEADER_AD)?);
    Ok(out)
}

fn hdecrypt(hk: Option<&[u8; 32]>, enc: &[u8]) -> Option<([u8; 32], u32, u32)> {
    let hk = hk?;
    if enc.len() != ENC_HEADER_LEN {
        return None;
    }
    let pt = p::aead_open(hk, &enc[..12], &enc[12..], HEADER_AD).ok()?;
    let mut dh = [0u8; 32];
    dh.copy_from_slice(&pt[..32]);
    let pn = u32::from_be_bytes(pt[32..36].try_into().ok()?);
    let n = u32::from_be_bytes(pt[36..40].try_into().ok()?);
    Some((dh, pn, n))
}

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
struct Skipped {
    hk: [u8; 32],
    n: u32,
    mk: [u8; 32],
}

#[derive(Clone)]
pub struct RatchetState {
    dhs: StaticSecret,
    dhr: Option<[u8; 32]>,
    rk: [u8; 32],
    cks: Option<[u8; 32]>,
    ckr: Option<[u8; 32]>,
    ns: u32,
    nr: u32,
    pn: u32,
    hks: Option<[u8; 32]>,
    hkr: Option<[u8; 32]>,
    nhks: Option<[u8; 32]>,
    nhkr: Option<[u8; 32]>,
    skipped: VecDeque<Skipped>,
}

impl Drop for RatchetState {
    fn drop(&mut self) {
        self.rk.zeroize();
        self.cks.zeroize();
        self.ckr.zeroize();
        self.hks.zeroize();
        self.hkr.zeroize();
        self.nhks.zeroize();
        self.nhkr.zeroize();
    }
}

impl RatchetState {
    pub fn init_alice(
        sk: &[u8; 32],
        bob_dh_pub: &[u8; 32],
        shared_hka: &[u8; 32],
        shared_nhkb: &[u8; 32],
    ) -> Result<Self> {
        let dhs = p::x25519_gen();
        let (rk, cks, nhks) = kdf_rk(sk, &p::dh(&dhs, bob_dh_pub)?);
        Ok(Self {
            dhs,
            dhr: Some(*bob_dh_pub),
            rk,
            cks: Some(cks),
            ckr: None,
            ns: 0,
            nr: 0,
            pn: 0,
            hks: Some(*shared_hka),
            hkr: None,
            nhks: Some(nhks),
            nhkr: Some(*shared_nhkb),
            skipped: VecDeque::new(),
        })
    }

    pub fn init_bob(sk: &[u8; 32], bob_dh: StaticSecret, shared_hka: &[u8; 32], shared_nhkb: &[u8; 32]) -> Self {
        Self {
            dhs: bob_dh,
            dhr: None,
            rk: *sk,
            cks: None,
            ckr: None,
            ns: 0,
            nr: 0,
            pn: 0,
            hks: None,
            hkr: None,
            nhks: Some(*shared_nhkb),
            nhkr: Some(*shared_hka),
            skipped: VecDeque::new(),
        }
    }

    pub fn encrypt(&mut self, pt: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
        let (cks, hks) = match (self.cks, self.hks) {
            (Some(c), Some(h)) => (c, h),
            _ => return fail("cannot send before receiving the first message"),
        };
        let (next, mut mk) = kdf_ck(&cks);
        self.cks = Some(next);
        let enc_header = hencrypt(&hks, &p::x25519_pub(&self.dhs), self.pn, self.ns)?;
        self.ns += 1;
        let mut full_ad = ad.to_vec();
        full_ad.extend_from_slice(&enc_header);
        let ct = msg_seal(&mk, pt, &full_ad);
        mk.zeroize();
        let mut out = enc_header;
        out.extend_from_slice(&ct?);
        Ok(out)
    }

    /// Transactional: works on a copy and commits only on success.
    pub fn decrypt(&mut self, wire: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
        if wire.len() < ENC_HEADER_LEN + p::AEAD_TAG_LEN {
            return fail("message too short");
        }
        let mut work = self.clone();
        let pt = work.decrypt_inner(&wire[..ENC_HEADER_LEN], &wire[ENC_HEADER_LEN..], ad)?;
        *self = work;
        Ok(pt)
    }

    fn decrypt_inner(&mut self, enc_header: &[u8], ct: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
        let mut full_ad = ad.to_vec();
        full_ad.extend_from_slice(enc_header);
        // 1) a previously skipped message?
        let hit = self
            .skipped
            .iter()
            .position(|s| matches!(hdecrypt(Some(&s.hk), enc_header), Some((_, _, n)) if n == s.n));
        if let Some(i) = hit {
            let s = self.skipped.remove(i).ok_or(Error::Crypto("skipped key missing"))?;
            return msg_open(&s.mk, ct, &full_ad);
        }
        // 2) current or next header key
        let (header, step) = match hdecrypt(self.hkr.as_ref(), enc_header) {
            Some(h) => (h, false),
            None => match hdecrypt(self.nhkr.as_ref(), enc_header) {
                Some(h) => (h, true),
                None => return fail("header did not decrypt"),
            },
        };
        let (dh_pub, pn, n) = header;
        if step {
            self.skip(pn)?;
            self.dh_ratchet(&dh_pub)?;
        }
        self.skip(n)?;
        let ckr = self.ckr.ok_or(Error::Crypto("no receiving chain"))?;
        let (next, mut mk) = kdf_ck(&ckr);
        self.ckr = Some(next);
        self.nr += 1;
        let r = msg_open(&mk, ct, &full_ad);
        mk.zeroize();
        r
    }

    fn skip(&mut self, until: u32) -> Result<()> {
        if until < self.nr {
            return fail("replayed or duplicate message");
        }
        if until - self.nr > MAX_SKIP {
            return fail("too many skipped messages");
        }
        let (mut ckr, hkr) = match (self.ckr, self.hkr) {
            (Some(c), Some(h)) => (c, h),
            _ => return Ok(()),
        };
        while self.nr < until {
            let (next, mk) = kdf_ck(&ckr);
            ckr = next;
            self.skipped.push_back(Skipped {
                hk: hkr,
                n: self.nr,
                mk,
            });
            self.nr += 1;
            while self.skipped.len() > MAX_STORED_SKIPPED {
                self.skipped.pop_front();
            }
        }
        self.ckr = Some(ckr);
        Ok(())
    }

    fn dh_ratchet(&mut self, dh_pub: &[u8; 32]) -> Result<()> {
        self.pn = self.ns;
        self.ns = 0;
        self.nr = 0;
        self.hks = self.nhks;
        self.hkr = self.nhkr;
        self.dhr = Some(*dh_pub);
        let (rk, ckr, nhkr) = kdf_rk(&self.rk, &p::dh(&self.dhs, dh_pub)?);
        self.rk = rk;
        self.ckr = Some(ckr);
        self.nhkr = Some(nhkr);
        self.dhs = p::x25519_gen();
        let (rk, cks, nhks) = kdf_rk(&self.rk, &p::dh(&self.dhs, dh_pub)?);
        self.rk = rk;
        self.cks = Some(cks);
        self.nhks = Some(nhks);
        Ok(())
    }

    /// Serialize for the encrypted local store. The caller must encrypt this at rest.
    pub fn export(&self) -> Result<String> {
        let snap = Snapshot {
            dhs: hex::encode(self.dhs.to_bytes()),
            dhr: self.dhr.map(hex::encode),
            rk: hex::encode(self.rk),
            cks: self.cks.map(hex::encode),
            ckr: self.ckr.map(hex::encode),
            ns: self.ns,
            nr: self.nr,
            pn: self.pn,
            hks: self.hks.map(hex::encode),
            hkr: self.hkr.map(hex::encode),
            nhks: self.nhks.map(hex::encode),
            nhkr: self.nhkr.map(hex::encode),
            skipped: self
                .skipped
                .iter()
                .map(|s| (hex::encode(s.hk), s.n, hex::encode(s.mk)))
                .collect(),
        };
        serde_json::to_string(&snap).map_err(|_| Error::Crypto("export failed"))
    }

    pub fn import(s: &str) -> Result<Self> {
        let d: Snapshot = serde_json::from_str(s).map_err(|_| Error::Crypto("bad ratchet snapshot"))?;
        let h = |x: &str| -> Result<[u8; 32]> {
            p::to32(&hex::decode(x).map_err(|_| Error::Crypto("bad hex"))?, "bad key length")
        };
        let o = |x: &Option<String>| -> Result<Option<[u8; 32]>> { x.as_deref().map(h).transpose() };
        let mut skipped = VecDeque::new();
        for (hk, n, mk) in &d.skipped {
            skipped.push_back(Skipped {
                hk: h(hk)?,
                n: *n,
                mk: h(mk)?,
            });
        }
        Ok(Self {
            dhs: StaticSecret::from(h(&d.dhs)?),
            dhr: o(&d.dhr)?,
            rk: h(&d.rk)?,
            cks: o(&d.cks)?,
            ckr: o(&d.ckr)?,
            ns: d.ns,
            nr: d.nr,
            pn: d.pn,
            hks: o(&d.hks)?,
            hkr: o(&d.hkr)?,
            nhks: o(&d.nhks)?,
            nhkr: o(&d.nhkr)?,
            skipped,
        })
    }
}

#[derive(Serialize, Deserialize)]
struct Snapshot {
    dhs: String,
    dhr: Option<String>,
    rk: String,
    cks: Option<String>,
    ckr: Option<String>,
    ns: u32,
    nr: u32,
    pn: u32,
    hks: Option<String>,
    hkr: Option<String>,
    nhks: Option<String>,
    nhkr: Option<String>,
    skipped: Vec<(String, u32, String)>,
}
