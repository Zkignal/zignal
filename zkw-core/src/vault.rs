//! Duress PIN vault: two equal-size slots, each opened by one PIN (Argon2id).
//! Nothing on disk says which slot is real; slot order is random; opening always
//! attempts both slots. Same layout as the Python reference.

use argon2::{Algorithm, Argon2, AssociatedData, ParamsBuilder, Version};
use zeroize::Zeroize;

use crate::error::{fail, Error, Result};
use crate::primitives as p;

pub const MAGIC: &[u8; 4] = b"ZWV1";
pub const SALT_LEN: usize = 16;
pub const SLOT_CAPACITY: usize = 1024;
pub const SLOT_LEN: usize = p::AEAD_NONCE_LEN + SLOT_CAPACITY + p::AEAD_TAG_LEN;
pub const VAULT_LEN: usize = 4 + SALT_LEN + 2 * SLOT_LEN;
pub const FLAG_WIPE_OTHER: u8 = 0x01;

#[derive(Clone, Copy, Debug)]
pub struct KdfParams {
    pub iterations: u32,
    pub memory_kib: u32,
    pub lanes: u32,
}

impl Default for KdfParams {
    /// Tune on a real iPhone; target roughly 0.5 s per unlock.
    fn default() -> Self {
        Self {
            iterations: 3,
            memory_kib: 64 * 1024,
            lanes: 4,
        }
    }
}

fn derive_key(pin: &str, salt: &[u8], kp: KdfParams) -> Result<[u8; 32]> {
    let ad = AssociatedData::new(p::L_VAULT).map_err(|_| Error::Crypto("argon2 ad"))?;
    let params = ParamsBuilder::new()
        .m_cost(kp.memory_kib)
        .t_cost(kp.iterations)
        .p_cost(kp.lanes)
        .output_len(32)
        .data(ad)
        .build()
        .map_err(|_| Error::Crypto("argon2 params"))?;
    let mut out = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(pin.as_bytes(), salt, &mut out)
        .map_err(|_| Error::Crypto("argon2 failed"))?;
    Ok(out)
}

fn slot_ad(i: u8) -> Vec<u8> {
    let mut ad = MAGIC.to_vec();
    ad.push(i);
    ad
}

fn seal_slot(key: &[u8; 32], secret: &[u8], flags: u8, i: u8) -> Result<Vec<u8>> {
    if secret.len() > SLOT_CAPACITY - 5 {
        return fail("secret too large for slot");
    }
    let mut pt = vec![flags];
    pt.extend_from_slice(&(secret.len() as u32).to_be_bytes());
    pt.extend_from_slice(secret);
    pt.extend_from_slice(&p::rand_vec(SLOT_CAPACITY - pt.len()));
    let nonce: [u8; 12] = p::rand_array();
    let mut out = nonce.to_vec();
    out.extend_from_slice(&p::aead_seal(key, &nonce, &pt, &slot_ad(i))?);
    pt.zeroize();
    Ok(out)
}

fn open_slot(key: &[u8; 32], slot: &[u8], i: u8) -> Option<(u8, Vec<u8>)> {
    let mut pt = p::aead_open(key, &slot[..12], &slot[12..], &slot_ad(i)).ok()?;
    let n = u32::from_be_bytes(pt[1..5].try_into().ok()?) as usize;
    let res = if 5 + n <= pt.len() {
        Some((pt[0], pt[5..5 + n].to_vec()))
    } else {
        None
    };
    pt.zeroize();
    res
}

pub fn create(
    real_pin: &str,
    real_secret: &[u8],
    duress_pin: &str,
    decoy_secret: &[u8],
    wipe_real_on_duress: bool,
    kp: KdfParams,
) -> Result<Vec<u8>> {
    if real_pin == duress_pin {
        return fail("PINs must differ");
    }
    let salt: [u8; SALT_LEN] = p::rand_array();
    let decoy_flags = if wipe_real_on_duress { FLAG_WIPE_OTHER } else { 0 };
    let mut entries = vec![(real_pin, real_secret, 0u8), (duress_pin, decoy_secret, decoy_flags)];
    if p::rand_array::<1>()[0] & 1 == 1 {
        entries.reverse();
    }
    let mut out = MAGIC.to_vec();
    out.extend_from_slice(&salt);
    for (i, (pin, secret, flags)) in entries.into_iter().enumerate() {
        let mut key = derive_key(pin, &salt, kp)?;
        out.extend_from_slice(&seal_slot(&key, secret, flags, i as u8)?);
        key.zeroize();
    }
    Ok(out)
}

#[derive(Debug, PartialEq, Eq)]
pub struct Opened {
    pub secret: Vec<u8>,
    pub slot: usize,
    pub wipe_other: bool,
}

/// Returns the matching profile, or None for a wrong PIN. Always tries both slots.
pub fn open_vault(vault: &[u8], pin: &str, kp: KdfParams) -> Result<Option<Opened>> {
    if vault.len() != VAULT_LEN || &vault[..4] != MAGIC {
        return fail("bad vault");
    }
    let salt = &vault[4..4 + SALT_LEN];
    let mut key = derive_key(pin, salt, kp)?;
    let base = 4 + SALT_LEN;
    let results: Vec<Option<(u8, Vec<u8>)>> = (0..2u8)
        .map(|i| {
            let s = base + i as usize * SLOT_LEN;
            open_slot(&key, &vault[s..s + SLOT_LEN], i)
        })
        .collect();
    key.zeroize();
    Ok(results.into_iter().enumerate().find_map(|(i, r)| {
        r.map(|(flags, secret)| Opened {
            secret,
            slot: i,
            wipe_other: flags & FLAG_WIPE_OTHER != 0,
        })
    }))
}

/// Overwrite one slot with random bytes of identical length.
pub fn wipe_slot(vault: &[u8], slot: usize) -> Vec<u8> {
    let mut v = vault.to_vec();
    let s = 4 + SALT_LEN + slot * SLOT_LEN;
    v[s..s + SLOT_LEN].copy_from_slice(&p::rand_vec(SLOT_LEN));
    v
}

/// App entry point: open, and apply the silent wipe if this profile requests it.
/// Returns (profile or None, vault bytes to persist).
pub fn unlock(vault: &[u8], pin: &str, kp: KdfParams) -> Result<(Option<Opened>, Vec<u8>)> {
    let opened = open_vault(vault, pin, kp)?;
    let new_vault = match &opened {
        Some(o) if o.wipe_other => wipe_slot(vault, 1 - o.slot),
        _ => vault.to_vec(),
    };
    Ok((opened, new_vault))
}
