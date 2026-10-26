# zkw-core: Zignal messaging protocol (Rust, v0.3)

Not audited. Rust implementation of the protocol defined by the Python reference in
`../zkw-ref`. The test vectors pin every derived key, tag, signature and memo byte, so both
implementations must agree exactly.

## Build and test

```bash
cargo test
```

| Test file | What it checks |
|---|---|
| `tests/vectors.rs` | Byte-for-byte agreement with `../zkw-ref/vectors/test_vectors.json` |
| `tests/protocol.rs` | End to end: invite and cold-contact handshakes, ratchet, out-of-order delivery, replay, tampering, forward secrecy, three-PIN vault (unlock, duress, panic) |
| `tests/persist.rs` | Encrypted save/restore across restarts (mid-conversation, skipped messages, cold contacts, replays), prekey rotation, profile key derivation |

## Modules

| File | What it does | Python twin |
|---|---|---|
| `src/primitives.rs` | X25519, Ed25519, ML-KEM-768, ChaCha20-Poly1305, HKDF; all protocol labels | `zkw/primitives.py` |
| `src/identity.rs` | Seed-derived identity, signed prekeys, safety number, invite codec | `zkw/identity.py` |
| `src/envelope.rs` | Fixed 512-byte memo format, chunking, reassembly | `zkw/envelope.py` |
| `src/ratchet.rs` | Double Ratchet with header encryption, transactional decrypt | `zkw/ratchet.py` |
| `src/session.rs` | Hybrid PQXDH handshake, sessions, HELLO/BUNDLE flow, inbox, replay protection | `zkw/session.py` |
| `src/vault.rs` | PIN vault (Argon2id, three identical slots: unlock, duress and panic PINs; opens version 1 two-slot vaults) | `zkw/vault.py` |
| `src/persist.rs` | Sealed inbox state (ChaCha20-Poly1305), profile key derivation | — |

## Beyond the Python reference

- Message keys, chain keys, header keys and vault keys are zeroized after use and on drop.
- Inbox state can be exported, sealed under a state key and restored after an app restart.
- Used by `../zkw-ffi`, which builds the Swift bindings and the iOS XCFramework.
