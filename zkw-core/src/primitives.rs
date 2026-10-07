//! Thin wrappers over vetted RustCrypto / dalek crates. No homegrown crypto.
//! Labels here are protocol constants and must match the Python reference exactly.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use ml_kem::kem::{Decapsulate, DecapsulationKey, Encapsulate, EncapsulationKey};
use ml_kem::{Ciphertext, EncodedSizeUser, KemCore, MlKem768, MlKem768Params, B32};
use rand_core::{OsRng, RngCore};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::error::{fail, Error, Result};

pub const L_IDENTITY: &[u8] = b"zkw/identity/v1";
pub const L_PQXDH: &[u8] = b"zkw/pqxdh/v1";
pub const L_INIT_ID: &[u8] = b"zkw/init-identity/v1";
pub const L_RK: &[u8] = b"zkw/ratchet/rk/v1";
pub const L_MSG: &[u8] = b"zkw/ratchet/msg/v1";
pub const L_CONVTAG: &[u8] = b"zkw/convtag/v1";
pub const L_SIG_SPK: &[u8] = b"zkw/sig/spk/v1";
pub const L_SIG_PQSPK: &[u8] = b"zkw/sig/pqspk/v1";
pub const L_SAFETY: &[u8] = b"zkw/safety/v1";
pub const L_VAULT: &[u8] = b"zkw/vault/v1";
pub const L_ID_BIND: &[u8] = b"zkw/sig/id-bind/v1";

pub const MLKEM768_PK_LEN: usize = 1184;
pub const MLKEM768_CT_LEN: usize = 1088;
pub const AEAD_TAG_LEN: usize = 16;
pub const AEAD_NONCE_LEN: usize = 12;

pub type MlKemDk = DecapsulationKey<MlKem768Params>;

// ---------- randomness ----------
pub fn rand_array<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    OsRng.fill_bytes(&mut b);
    b
}

pub fn rand_vec(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    OsRng.fill_bytes(&mut b);
    b
}

// ---------- KDF / MAC ----------
pub fn hkdf(ikm: &[u8], salt: Option<&[u8]>, info: &[u8], len: usize) -> Vec<u8> {
    let h = Hkdf::<Sha256>::new(salt, ikm);
    let mut out = vec![0u8; len];
    h.expand(info, &mut out)
        .expect("HKDF output length is always valid here");
    out
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    m.update(data);
    let mut out = [0u8; 32];
    out.copy_from_slice(&m.finalize().into_bytes());
    out
}

pub fn to32(b: &[u8], what: &'static str) -> Result<[u8; 32]> {
    b.try_into().map_err(|_| Error::Crypto(what))
}

// ---------- X25519 ----------
pub fn x25519_gen() -> StaticSecret {
    StaticSecret::random_from_rng(OsRng)
}

pub fn x25519_pub(s: &StaticSecret) -> [u8; 32] {
    PublicKey::from(s).to_bytes()
}

pub fn dh(s: &StaticSecret, peer_pub: &[u8]) -> Result<[u8; 32]> {
    let pk = to32(peer_pub, "x25519 public key must be 32 bytes")?;
    let ss = s.diffie_hellman(&PublicKey::from(pk));
    // Reject all-zero output (small-order point), RFC 7748 section 6.1.
    if !ss.was_contributory() {
        return fail("invalid DH output");
    }
    Ok(*ss.as_bytes())
}

// ---------- Ed25519 ----------
pub fn sign(k: &SigningKey, label: &[u8], msg: &[u8]) -> [u8; 64] {
    let mut m = Vec::with_capacity(label.len() + msg.len());
    m.extend_from_slice(label);
    m.extend_from_slice(msg);
    k.sign(&m).to_bytes()
}

pub fn verify(pubk: &[u8], label: &[u8], msg: &[u8], sig: &[u8]) -> Result<()> {
    let pk = to32(pubk, "ed25519 public key must be 32 bytes")?;
    let vk = VerifyingKey::from_bytes(&pk).map_err(|_| Error::Crypto("bad ed25519 public key"))?;
    let s: [u8; 64] = sig
        .try_into()
        .map_err(|_| Error::Crypto("ed25519 signature must be 64 bytes"))?;
    let mut m = Vec::with_capacity(label.len() + msg.len());
    m.extend_from_slice(label);
    m.extend_from_slice(msg);
    vk.verify_strict(&m, &Signature::from_bytes(&s))
        .map_err(|_| Error::Crypto("bad signature"))
}

// ---------- ML-KEM-768 (FIPS 203) ----------
/// Returns (decapsulation key, encoded public key).
pub fn mlkem_gen() -> (MlKemDk, Vec<u8>) {
    let (dk, ek) = MlKem768::generate(&mut OsRng);
    (dk, ek.as_bytes().to_vec())
}

/// 64-byte seed = d || z (FIPS 203), same as pyca/cryptography `from_seed_bytes`.
pub fn mlkem_from_seed(seed: &[u8]) -> Result<(MlKemDk, Vec<u8>)> {
    if seed.len() != 64 {
        return fail("ml-kem seed must be 64 bytes");
    }
    let mut d = B32::default();
    d.copy_from_slice(&seed[..32]);
    let mut z = B32::default();
    z.copy_from_slice(&seed[32..]);
    let (dk, ek) = MlKem768::generate_deterministic(&d, &z);
    Ok((dk, ek.as_bytes().to_vec()))
}

/// Returns (ciphertext, shared secret).
pub fn mlkem_encaps(pubk: &[u8]) -> Result<(Vec<u8>, [u8; 32])> {
    if pubk.len() != MLKEM768_PK_LEN {
        return fail("ml-kem public key must be 1184 bytes");
    }
    let mut enc = ml_kem::Encoded::<EncapsulationKey<MlKem768Params>>::default();
    enc.copy_from_slice(pubk);
    let ek = EncapsulationKey::<MlKem768Params>::from_bytes(&enc);
    let (ct, ss) = ek
        .encapsulate(&mut OsRng)
        .map_err(|_| Error::Crypto("ml-kem encapsulation failed"))?;
    Ok((ct.to_vec(), to32(&ss, "ml-kem shared secret")?))
}

pub fn mlkem_decaps(dk: &MlKemDk, ct: &[u8]) -> Result<[u8; 32]> {
    if ct.len() != MLKEM768_CT_LEN {
        return fail("ml-kem ciphertext must be 1088 bytes");
    }
    let mut c = Ciphertext::<MlKem768>::default();
    c.copy_from_slice(ct);
    let ss = dk
        .decapsulate(&c)
        .map_err(|_| Error::Crypto("ml-kem decapsulation failed"))?;
    to32(&ss, "ml-kem shared secret")
}

// ---------- AEAD: ChaCha20-Poly1305 ----------
pub fn aead_seal(key: &[u8], nonce: &[u8], pt: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
    if key.len() != 32 || nonce.len() != AEAD_NONCE_LEN {
        return fail("bad aead key or nonce length");
    }
    ChaCha20Poly1305::new(Key::from_slice(key))
        .encrypt(Nonce::from_slice(nonce), Payload { msg: pt, aad: ad })
        .map_err(|_| Error::Crypto("aead seal failed"))
}

pub fn aead_open(key: &[u8], nonce: &[u8], ct: &[u8], ad: &[u8]) -> Result<Vec<u8>> {
    if key.len() != 32 || nonce.len() != AEAD_NONCE_LEN {
        return fail("bad aead key or nonce length");
    }
    if ct.len() < AEAD_TAG_LEN {
        return fail("ciphertext too short");
    }
    ChaCha20Poly1305::new(Key::from_slice(key))
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad: ad })
        .map_err(|_| Error::Crypto("authentication failed"))
}
