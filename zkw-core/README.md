# zkw-core (Rust) — protocol v0.2
CONFIDENTIAL. Not audited. Rust port of `../zkw-ref` (Python reference).

## First run on the Mac (Terminal app, not the Claude sandbox)
```bash
# 1. Install Rust (one time). Accept the defaults.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# 2. Build and test
cd ~/Documents/Zignal/zkw-core
cargo test 2>&1 | tee test-output.txt
```
`test-output.txt` lands in this folder, so Claude can read it directly.

This code was written without a compiler (the Claude sandbox can't download crates), so the
first build may hit a few small compile errors. That's expected; Claude fixes them from
`test-output.txt`.

## What passing means
- `tests/vectors.rs`: every derived key, tag, signature, and memo byte matches the Python reference exactly
- `tests/protocol.rs`: the 20 end-to-end checks (handshake, ratchet, replay, tamper, forward secrecy, duress vault)

## Layout
| File | Python twin |
|---|---|
| `src/primitives.rs` | `zkw/primitives.py` |
| `src/identity.rs` | `zkw/identity.py` |
| `src/envelope.rs` | `zkw/envelope.py` |
| `src/ratchet.rs` | `zkw/ratchet.py` |
| `src/session.rs` | `zkw/session.py` |
| `src/vault.rs` | `zkw/vault.py` |

## Improvements over the Python reference
- Message keys, chain keys, header keys and vault keys are zeroized after use and on drop.
- Built as a static library (`staticlib`) ready to link into iOS.

## Next (after tests pass)
1. iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`
2. UniFFI bindings so Swift can call `Inbox`, `Session`, `vault`
3. Package as an XCFramework and add it to the Zodl iOS fork
