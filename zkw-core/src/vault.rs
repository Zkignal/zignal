//! PIN vault: three equal-size slots, each opened by one PIN (Argon2id).
//!
//! - The unlock PIN opens the real profile, the duress PIN opens the decoy profile, and the
//!   panic PIN opens the decoy too, after silently wiping the real profile's slot.
//! - Nothing on disk says which slot is which, and the slot order is random. Every attempt
//!   runs Argon2id once and then tries every slot, so timing doesn't reveal which PIN matched.
//! - The panic slot records which slot to wipe inside its own encrypted contents.
//! - Two-slot vaults from v1 ("ZWV1") still open and wipe as before.
//!
//! Same layout as the Python reference.

use argon2::{Algorithm, Argon2, AssociatedData, ParamsBuilder, Version};
use zeroize::Zeroize;

use crate::error::{fail, Error, Result};
use crate::primitives as p;

pub const MAGIC: &[u8; 4] = b"ZWV2";
pub const MAGIC_V1: &[u8; 4] = b"ZWV1";
pub const SALT_LEN: usize = 16;
pub const SLOT_CAPACITY: usize = 1024;
pub const SLOT_LEN: usize = p::AEAD_NONCE_LEN + SLOT_CAPACITY + p::AEAD_TAG_LEN;
pub const SLOTS: usize = 3;
pub const VAULT_LEN: usize = 4 + SALT_LEN + SLOTS * SLOT_LEN;
pub const VAULT_V1_LEN: usize = 4 + SALT_LEN + 2 * SLOT_LEN;
/// v1 only: opening this slot wipes the other one.
pub const FLAG_WIPE_OTHER: u8 = 0x01;
/// v2: opening this slot wipes the slot whose index is stored in bits 4 and 5 of the flags.
pub const FLAG_WIPE_TARGET: u8 = 0x02;

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

fn slot_ad(magic: &[u8; 4], i: u8) -> Vec<u8> {
    let mut ad = magic.to_vec();
    ad.push(i);
    ad
}

fn seal_slot(key: &[u8; 32], secret: &[u8], flags: u8, magic: &[u8; 4], i: u8) -> Result<Vec<u8>> {
    if secret.len() > SLOT_CAPACITY - 5 {
        return fail("secret too large for slot");
    }
    let mut pt = vec![flags];
    pt.extend_from_slice(&(secret.len() as u32).to_be_bytes());
    pt.extend_from_slice(secret);
    pt.extend_from_slice(&p::rand_vec(SLOT_CAPACITY - pt.len()));
    let nonce: [u8; 12] = p::rand_array();
    let mut out = nonce.to_vec();
    out.extend_from_slice(&p::aead_seal(key, &nonce, &pt, &slot_ad(magic, i))?);
    pt.zeroize();
    Ok(out)
}

fn open_slot(key: &[u8; 32], slot: &[u8], magic: &[u8; 4], i: u8) -> Option<(u8, Vec<u8>)> {
    let mut pt = p::aead_open(key, &slot[..12], &slot[12..], &slot_ad(magic, i)).ok()?;
    let n = u32::from_be_bytes(pt[1..5].try_into().ok()?) as usize;
    let res = if 5 + n <= pt.len() {
        Some((pt[0], pt[5..5 + n].to_vec()))
    } else {
        None
    };
    pt.zeroize();
    res
}

/// A random slot order: `order[slot]` is the index of the entry stored in that slot.
fn shuffled_order() -> [usize; SLOTS] {
    let mut order = [0, 1, 2];
    for i in (1..SLOTS).rev() {
        let j = u32::from_be_bytes(p::rand_array::<4>()) as usize % (i + 1);
        order.swap(i, j);
    }
    order
}

/// Creates a vault for three different PINs. The panic PIN opens the decoy profile and
/// silently wipes the real profile's slot.
pub fn create(
    real_pin: &str,
    real_secret: &[u8],
    duress_pin: &str,
    decoy_secret: &[u8],
    panic_pin: &str,
    kp: KdfParams,
) -> Result<Vec<u8>> {
    if real_pin == duress_pin || real_pin == panic_pin || duress_pin == panic_pin {
        return fail("PINs must differ");
    }
    let salt: [u8; SALT_LEN] = p::rand_array();
    let order = shuffled_order();
    let real_slot = order.iter().position(|&entry| entry == 0).unwrap_or(0) as u8;
    let entries = [
        (real_pin, real_secret, 0u8),
        (duress_pin, decoy_secret, 0u8),
        (panic_pin, decoy_secret, FLAG_WIPE_TARGET | (real_slot << 4)),
    ];
    let mut out = MAGIC.to_vec();
    out.extend_from_slice(&salt);
    for (slot, &entry) in order.iter().enumerate() {
        let (pin, secret, flags) = entries[entry];
        let mut key = derive_key(pin, &salt, kp)?;
        out.extend_from_slice(&seal_slot(&key, secret, flags, MAGIC, slot as u8)?);
        key.zeroize();
    }
    Ok(out)
}

/// Creates a v1 (two-slot) vault. Kept only so tests can check that older vaults still open.
#[doc(hidden)]
pub fn create_v1(
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
    let mut out = MAGIC_V1.to_vec();
    out.extend_from_slice(&salt);
    for (i, (pin, secret, flags)) in entries.into_iter().enumerate() {
        let mut key = derive_key(pin, &salt, kp)?;
        out.extend_from_slice(&seal_slot(&key, secret, flags, MAGIC_V1, i as u8)?);
        key.zeroize();
    }
    Ok(out)
}

#[derive(Debug, PartialEq, Eq)]
pub struct Opened {
    pub secret: Vec<u8>,
    pub slot: usize,
    /// The slot this PIN silently wipes when it opens, if any.
    pub wipes: Option<usize>,
}

/// The vault's magic and number of slots, or an error for anything that isn't a vault.
fn layout(vault: &[u8]) -> Result<(&'static [u8; 4], usize)> {
    match (vault.get(..4), vault.len()) {
        (Some(m), VAULT_LEN) if m == &MAGIC[..] => Ok((MAGIC, SLOTS)),
        (Some(m), VAULT_V1_LEN) if m == &MAGIC_V1[..] => Ok((MAGIC_V1, 2)),
        _ => fail("bad vault"),
    }
}

/// Which slot opening `slot` wipes, from its flags.
fn wipe_target(magic: &[u8; 4], flags: u8, slot: usize, slots: usize) -> Option<usize> {
    if magic == MAGIC_V1 {
        return (flags & FLAG_WIPE_OTHER != 0).then_some(1 - slot);
    }
    if flags & FLAG_WIPE_TARGET == 0 {
        return None;
    }
    let target = ((flags >> 4) & 0x03) as usize;
    (target < slots && target != slot).then_some(target)
}

/// Returns the matching profile, or None for a wrong PIN. Always tries every slot.
pub fn open_vault(vault: &[u8], pin: &str, kp: KdfParams) -> Result<Option<Opened>> {
    let (magic, slots) = layout(vault)?;
    let salt = &vault[4..4 + SALT_LEN];
    let mut key = derive_key(pin, salt, kp)?;
    let base = 4 + SALT_LEN;
    let results: Vec<Option<(u8, Vec<u8>)>> = (0..slots)
        .map(|i| {
            let s = base + i * SLOT_LEN;
            open_slot(&key, &vault[s..s + SLOT_LEN], magic, i as u8)
        })
        .collect();
    key.zeroize();
    Ok(results.into_iter().enumerate().find_map(|(i, r)| {
        r.map(|(flags, secret)| Opened {
            secret,
            slot: i,
            wipes: wipe_target(magic, flags, i, slots),
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

/// App entry point: open, and apply the silent wipe if this PIN requests one.
/// Returns (profile or None, vault bytes to persist).
pub fn unlock(vault: &[u8], pin: &str, kp: KdfParams) -> Result<(Option<Opened>, Vec<u8>)> {
    let opened = open_vault(vault, pin, kp)?;
    let new_vault = match opened.as_ref().and_then(|o| o.wipes) {
        Some(target) => wipe_slot(vault, target),
        None => vault.to_vec(),
    };
    Ok((opened, new_vault))
}
