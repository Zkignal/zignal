# zkw reference implementation (protocol v0.2)
CONFIDENTIAL. Not audited. Reference only; do not use with real funds or secrets.

Python reference for the private Zcash-memo messenger. Its job: prove the design
works and pin down exact bytes, so the iOS port (Rust via UniFFI, or Swift) can be
checked against `vectors/test_vectors.json`.

## Run
```
python3 -m unittest -v          # 28 tests
python3 -m vectors.generate     # regenerate vectors (only after a deliberate protocol change)
```
Needs Python 3.11+ and `cryptography` >= 47 (for ML-KEM). Nothing else.

## Layout
| File | What it does |
|---|---|
| `zkw/primitives.py` | Wrappers over pyca/cryptography: X25519, Ed25519, ML-KEM-768, ChaCha20-Poly1305, HKDF. All protocol labels live here. |
| `zkw/identity.py` | Seed-derived identity, signed prekeys, safety number, QR/link invite codec |
| `zkw/envelope.py` | Fixed 512-byte memo format, chunking, reassembly |
| `zkw/ratchet.py` | Double Ratchet with header encryption; transactional decrypt; persistence |
| `zkw/session.py` | Hybrid PQXDH handshake, sessions, cold HELLO/BUNDLE flow, inbox router, replay protection |
| `zkw/vault.py` | Duress PIN vault (Argon2id, two identical slots, optional silent wipe) |
| `tests/test_protocol.py` | End-to-end and unit tests |
| `vectors/` | Deterministic vectors for the ports |

## What the tests prove
- Invite (QR) and cold-contact (HELLO, BUNDLE, INIT) flows both work end to end
- 25 rounds of back-and-forth with ratchet steps; out-of-order delivery; long messages chunked
- Replayed messages and replayed handshakes are ignored; invites are single-use
- A tampered memo is rejected and leaves session state untouched
- A third party with their own keys can't read anything
- Forward secrecy: stealing current session state does not decrypt earlier messages
- No sender identity key or address appears in clear in any memo
- Receipts and reactions are indistinguishable from text messages on the wire
- Identity-key substitution in a prekey bundle is caught
- Duress vault: real PIN, duress PIN, wrong PIN, identical file size, silent wipe, no wipe by default

## Measured sizes
- Single-memo text: up to 403 bytes (512 minus 24 envelope, 68 encrypted header, 16 tag, 1 kind byte)
- Handshake (INIT plus first message): 4 memos in one transaction
- Duress vault file: 2,124 bytes. Production PIN derivation: about 0.1 s to unlock on this machine (Argon2id, 64 MiB)

## Changes from spec v0.1 (fold into v0.2 spec)
1. **AEAD fixed:** ChaCha20-Poly1305.
2. **Envelope:** added a 2-byte `body_len` at offset 22 so random padding can be stripped; chunk index and total are 1 byte each. Header is 24 bytes; max body 488.
3. **Safety number:** SHA-512 (not SHA-256), so 60 digits come from 60 bytes.
4. **Identity binding:** the signed-prekey signature now also covers the X25519 identity key, and the initiator sends a binding signature. Blocks an attacker pairing your signing key with their own DH key.
5. **Initiator identity encrypted:** INIT hides Alice's identity keys and address under a key from DH(EK, SPK) plus the KEM secret. Someone holding only Bob's viewing key can't see who is contacting him.
6. **All post-handshake traffic is type MSG:** the real kind (text, receipt, reaction, close) is inside the encryption.
7. **conv_tag epoch:** one day; receivers accept yesterday, today and tomorrow.
8. **Duress wipe:** the app can't know which slot is real, so the wipe flag is stored encrypted inside the decoy slot.

## Known limits / to do in the port
- Python can't zeroize memory. Rust/Swift must wipe message keys, chain keys and PINs after use.
- Argon2id parameters should be tuned on a real iPhone (target about 0.5 s).
- Prekey rotation timing, multi-device, and groups are out of scope for the hackathon.
- Zcash plumbing (building the shielded transaction, reading memos) is the wallet's job. This code only produces and consumes 512-byte memos.

## Port plan (on the Mac)
1. Allow crates.io, or build on the Mac.
2. Rust crate mirroring these modules: x25519-dalek, ed25519-dalek, ml-kem, chacha20poly1305, hkdf, argon2.
3. Pass every value in `vectors/test_vectors.json`, then port the end-to-end tests.
4. UniFFI bindings into the Zodl iOS fork as the `MessagingCryptoClient` and `EnvelopeCodecClient` dependencies.
