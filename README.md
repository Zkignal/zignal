# Zignal

End-to-end encrypted messaging carried inside Zcash shielded transactions.

Every message is a 512-byte encrypted memo in an Orchard shielded output. On top of
Zcash's own memo encryption, Zignal adds a post-quantum hybrid handshake and a
Double Ratchet, so a leaked wallet key doesn't expose past messages and the sender's
identity never appears in clear, even to someone holding the recipient's viewing key.

> **Status:** experimental, built for the Zecathon (Oct 2026). Not audited.
> Do not rely on it to protect anything important yet.

## Repository layout

| Path | What it is |
|---|---|
| `zkw-core/` | Rust messaging core: memo envelope, handshake, Double Ratchet, inbox, duress vault |
| `zkw-ref/` | Python reference implementation and test vectors (the protocol's ground truth) |
| `zkw-ffi/` | Swift bindings for `zkw-core` (UniFFI) and the iOS XCFramework build script |
| `ios/Zignal/` | SwiftUI iOS app using the Zcash Swift SDK (`ZcashLightClientKit`) |

## Protocol at a glance

- **Transport:** one shielded Zcash transaction per message; long messages are split across
  up to 15 memo outputs in the same transaction (ZIP-321 multi-output).
- **Envelope:** fixed 512 bytes, 24-byte header, up to 403 bytes of text per memo,
  random padding. Receipts and reactions are indistinguishable from text on the wire.
- **Handshake:** PQXDH-style hybrid of X25519 and ML-KEM-768 (FIPS 203), with signed prekeys.
  The initiator's identity is encrypted inside the handshake.
- **Messages:** Double Ratchet with header encryption (forward secrecy and post-compromise security).
- **Contacts:** QR/link invite, or a cold request that the recipient must accept. Each contact
  gets its own receive address. Contacts verify each other with a 60-digit safety number.
- **Conversation lookup:** a rotating daily tag instead of any sender identifier.
- **Duress PIN:** two equal-size encrypted profiles; a duress PIN opens a decoy profile and
  nothing on disk shows which profile is real.
- **Primitives:** X25519, Ed25519, ML-KEM-768, ChaCha20-Poly1305, HKDF-SHA256, Argon2id,
  all from audited RustCrypto / dalek crates. No custom primitives.

## Build and test

Requirements: macOS with Xcode, Rust (`rustup`), Python 3.11+ with `cryptography` (reference only).

```bash
# Rust core: 24 tests, including byte-for-byte checks against the Python reference
cd zkw-core && cargo test

# Python reference: 28 tests
cd zkw-ref && python3 -m unittest -v

# Swift bindings + iOS XCFramework
cd zkw-ffi && ./build-ios.sh
```

Then open `ios/Zignal/Zignal.xcodeproj` and run on an iPhone simulator.

## Security notes

- Not audited. Treat as experimental software.
- Zcash shielded transactions hide sender, recipient and amount on-chain. Network-level
  metadata (your IP, timing) is a separate problem; use Tor or your own lightwalletd server.
- Each message costs a normal Zcash network fee and takes about one block (~75 s) to arrive.
- Wallet keys never leave the device. Zignal has no accounts, no phone numbers, no servers of its own.

## License

MIT OR Apache-2.0 (dual-licensed).
