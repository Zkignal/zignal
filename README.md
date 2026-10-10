# Zignal

End-to-end encrypted messaging carried inside Zcash shielded transactions.

Every message travels as 512-byte encrypted memos in shielded outputs. On top of Zcash's
own memo encryption, Zignal adds a post-quantum hybrid handshake and a Double Ratchet, so a
leaked wallet key doesn't expose past messages, and the sender's identity never appears in
clear, even to someone holding the recipient's viewing key.

> **Status:** experimental, built for the Zecathon (October 2026). Not audited.
> Do not rely on it to protect anything important yet.

## What works today

- **Messaging core (Rust):** memo envelope, hybrid post-quantum handshake, Double Ratchet,
  inbox with contact requests, replay protection, encrypted save/restore, duress vault.
  Checked byte for byte against an independent Python reference.
- **Swift bindings:** the Rust core is compiled into the iOS app as an XCFramework (UniFFI).
- **iOS app:**
  - Set an unlock PIN and a duress PIN.
  - The duress PIN opens a separate decoy profile.
  - Encrypted on-device storage.
  - Lock on background.
  - Chat list, conversations and safety-number verification.
  - A demo contact that lives on the phone, so every message runs the full protocol
    (handshake, ratchet, 512-byte memos) without a network.
- **In progress:** the wallet layer on the Zcash Swift SDK (testnet first), which turns the
  demo into real messages between phones.

## Repository layout

| Path | What it is |
|---|---|
| `zkw-core/` | Rust messaging core: memo envelope, handshake, Double Ratchet, inbox, persistence, duress vault |
| `zkw-ref/` | Python reference implementation and test vectors (the protocol's ground truth) |
| `zkw-ffi/` | Swift bindings for `zkw-core` (UniFFI) and the iOS XCFramework build script |
| `ios/Zignal/` | SwiftUI iOS app: `Core/` (storage, vault, sessions), `UI/` (screens), `Generated/` (bindings) |

## Protocol at a glance

- **Transport:** one shielded Zcash transaction per message; long messages are split across
  up to 15 memo outputs in the same transaction (ZIP-321 multi-output).
- **Envelope:**
  - Fixed 512 bytes: a 25-byte header, up to 402 bytes of text per memo, and random padding.
  - The first byte is `0xFF`, which marks the memo as binary data under ZIP-302, so wallets
    never try to read it as text.
  - Receipts and reactions are indistinguishable from text on the wire.
- **Handshake:** PQXDH-style hybrid of X25519 and ML-KEM-768 (FIPS 203), with signed prekeys.
  The initiator's identity is encrypted inside the handshake.
- **Messages:** Double Ratchet with header encryption (forward secrecy and post-compromise security).
- **Contacts:** QR/link invite, or a cold request that the recipient must accept. Each contact
  gets its own receive address. Contacts verify each other with a 60-digit safety number.
- **Conversation lookup:** a rotating daily tag instead of any sender identifier.
- **Primitives:** X25519, Ed25519, ML-KEM-768, ChaCha20-Poly1305, HKDF-SHA256, Argon2id,
  all from audited RustCrypto / dalek crates. No custom primitives.

## How the iOS app protects data on the phone

**PINs**
- Your unlock PIN and duress PIN each unlock one profile in a fixed-size vault (Argon2id,
  64 MiB).
- The vault is stored in the Keychain, readable only while the phone is unlocked, and never
  synced or moved to another device.
- Wrong PINs trigger a growing wait, and force-quitting the app doesn't reset the count.

**Duress**
- The duress PIN opens a decoy profile that looks like a normal one.
- Optionally, it also silently destroys the real profile.
- The app never shows which profile is open.

**Storage**
- Each profile's data is sealed under that profile's own key, inside a second layer sealed
  under a device key.
- Every save rewrites all profile files to one common size with the same timestamps, so the
  files change together whichever profile is in use.
- Data is saved before anything is sent, so a crash can't cause message keys to be reused.
- Files use complete data protection and are excluded from device backups. Chat state must
  never come back from a backup: an old ratchet state could reuse message keys.

**Screen and input**
- The app locks when it goes to the background.
- A cover window hides it, including open sheets and alerts, in the app switcher.
- Third-party keyboards are blocked, and the message box has autocorrect off.
- Received text is shown verbatim, never rendered as Markdown or links.

**Logging and network**
- The app has no logging and no analytics.
- The current build makes no network connections.

## Build and test

Requirements: macOS with Xcode, Rust (`rustup`), Python 3.11+ with `cryptography` (reference only).

```bash
# Rust core: 32 tests, including byte-for-byte checks against the Python reference
cd zkw-core && cargo test

# Python reference: 28 tests
cd zkw-ref && python3 -m unittest -v

# Swift bindings + iOS XCFramework (also runs the binding tests)
cd zkw-ffi && ./build-ios.sh
```

Then open `ios/Zignal/Zignal.xcodeproj`:
- Cmd+U runs the 18 app tests: PIN rules, storage encryption and tamper checks, the duress
  vault, and demo chat across restarts.
- Cmd+R runs the app on an iPhone simulator.

## Security notes and known limitations

- **Not audited.** Treat as experimental software.
- **On-chain:** Zcash shielded transactions hide sender, recipient and amount. Your IP address
  and timing are a separate problem.
- **Network privacy:** the Zcash SDK's built-in Tor support covers only part of a wallet's
  traffic. Running your own lightwalletd server is the strongest option.
- **Cost and delay:** each message costs a normal Zcash network fee and arrives after about
  one block (~75 s).
- **No servers:** wallet keys never leave the device, and Zignal has no accounts, no phone
  numbers and no servers of its own.
- **PIN strength:** a 6-digit PIN can be brute-forced offline by someone who extracts the
  Keychain from an unlocked phone. Use 8 or more digits for real use.
- **Clock:** moving the phone's clock forward shortens the wrong-PIN wait.
- **Memory:** Swift can't reliably wipe key material from memory after lock. The Rust core
  does wipe its own copies.
- **Decoy realism:** a decoy profile is only convincing if it's used now and then.

## Development log

All code in this repository was written during the Zecathon build window. Dates match the
git history.

| Date | Milestone |
|---|---|
| 2026-10-06 | Protocol v0.2: Python reference (28 tests) and Rust core with byte-exact test vectors |
| 2026-10-07 | Swift bindings (UniFFI), iOS app on the Zcash Swift SDK, encrypted inbox save/restore, Rust core linked into the app |
| 2026-10-08 | iOS app: PIN setup, duress unlock, encrypted two-layer profile storage, demo chat, 18 app tests. Review of Zcash Swift SDK 3.0.0: memo format, NU6.3 Ironwood pool, multi-output sends, fees, Tor coverage |
| 2026-10-10 | Protocol v0.3: memos start with `0xFF` (ZIP-302 binary data) so the Zcash SDK and other wallets accept them |

## License

MIT OR Apache-2.0 (dual-licensed).
