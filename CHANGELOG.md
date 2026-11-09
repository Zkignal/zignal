# Changelog

Every change on the `dev` branch since the Zecathon submission, newest first. Each fix adds
its entry here in the same commit.

- `main` (tag `zecathon-final`, October 28, 2026) is the submission and stays as submitted
  until judging ends.
- `nu7` (tag `zecathon-nu7`) is the submission plus only the SDK update for NU7.
- There are no version numbers yet, so each entry names its commits. Dates are commit dates.

## 2026-11-09

### Security
- **Limits on what strangers can store.** Zignal's core keeps at most 32 contact requests and
  64 incomplete multi-memo messages, and drops the oldest first. Before, anyone with one of
  your addresses could add them without a limit for the price of a fee, and requests are saved
  with the profile. In `zkw-core` and the Python reference, with 2 new tests in each.
  (`3f28c77`)

### Documentation
- The README lists what the November reviews found and what's planned: the trace a panic
  wipe leaves in the wallet folder, how far a short PIN holds against a forensic copy of the
  vault, and the wrong-PIN wait that follows the clock.
- This changelog, and a security policy (`SECURITY.md`): how to report a vulnerability
  privately, what's in scope and the testing rules. The README links both, and its "Try it"
  dates and the Python reference's test count are brought up to date. (`9df2f92`)
- The README lists the hidden recovery words, the "Checking" label and the limits on stored
  state, the tests from November 1 to 7 and the Tor library version
  ([zcash/librustzcash#3246](https://github.com/zcash/librustzcash/issues/3246)), and it has
  two screenshots of the hidden recovery words. (`c6a9e82`)

## 2026-11-07

### Security
- **The recovery words are hidden while the screen is recorded, mirrored or shared**, on the
  recovery phrase screen and in the restore field, and a notice says why. iOS can't block
  screenshots, so a screenshot taken while the words show brings up a warning to delete it.
  (`d9ff597`)

### Fixed
- **"Checking whether it went out…"** replaces the red "Not sent" for the few seconds after
  unlocking while the wallet checks a send that a lock cut short. (`220eba7`)
- **"Tap to send again" sends the same transaction again** when the wallet still holds it,
  instead of building a new one. The Zcash SDK resends a failed send's transaction every few
  minutes on its own until it expires, so a new transaction could be paid for twice.
  (`96668c4`)
- **Sending and receiving are more robust.** A new contact's second message is no longer lost
  when it arrives before their first. A send cut short by a lock shows "sent" while its
  transaction waits to be mined, instead of "Not sent". A double tap on "Tap to send again"
  can't send a message twice. (`3a78a62`)

### Changed
- **Add funds says received ZEC can be spent in about 4 minutes:** NU7's 25-second blocks
  make the 10 confirmations take about 4 minutes instead of 12. (`8c6a7f8`)

### Documentation
- The README says what `dev` changes compared with the submission, with the branches, the
  changes and their reasons. (`fe61388`)

## 2026-11-04

### Security
- **Security updates in the SDK's Rust dependencies**, all patch releases: `zstd` 0.13.4,
  `zstd-safe` 7.4.0, `zstd-sys` 2.1.2, `tokio` 1.53.3 and `event-listener` 5.4.2. They fix
  RUSTSEC-2026-0391, -0398, -0403, -0410, -0386 and -0221. Two advisories remain, through the
  Tor client (arti 0.43), with no compatible fix yet: RUSTSEC-2023-0071 (`rsa`) and
  RUSTSEC-2026-0387 (`crypto-bigint`). (`a10e69c`, merged in `d90ffdd`)

### Changed
- The SDK's Rust library builds with no compiler warnings. (`a10e69c`)

## 2026-11-03

### Fixed
- **Interrupted sends are no longer shown as failed.** A message sent just before the app was
  locked shows "Not sent" at first. Once the wallet sees its transaction in a block, it turns
  "delivered" by itself, and "Tap to send again" checks this first. (`5c173ee`)

## 2026-11-01

### Security
- **Updated TLS libraries** for connections made from Rust (Tor): `rustls` 0.23.46,
  `rustls-webpki` 0.103.16, `webpki-roots` 1.0.11 and `h2` 0.4.20. They stop trusting the
  eight compromised eMudhra intermediate CAs disclosed on October 20, 2026, and fix RustSec
  advisories in `rustls` and `h2`. (`829ecb0`)

### Added
- **NU7 support.** The SDK's Rust library (`libzcashlc`) is built from source on
  librustzcash's NU7 releases (`zcash_protocol` 0.11, `zcash_client_backend` 0.25,
  `zcash_client_sqlite` 0.23, `orchard` 0.16). Before, it was ECC's prebuilt 3.0.0 binary,
  which has no NU7 mainnet height. (`829ecb0`, `f66c1c3`, merged in `2842276`)

### Changed
- **Smaller SDK:** EIP-681 payment links and the pool migration, which Zignal doesn't use,
  are left out of the library (about 13,000 lines). Stubs keep the same C declarations, so
  the Swift code is unchanged. (`829ecb0`)
- **The build keeps the builder out of the library.** File paths from the build machine are
  removed, and the build stops if any remain. The library targets iOS 17.0, the app's
  minimum. (`f66c1c3`)

## 2026-10-29

### Changed
- **Prepare** (formerly "Prepare for chatting") splits your balance only when it helps. It
  waits while recent messages' change confirms instead of splitting again, and the button
  shows Ready, Confirming or Prepare, with one line saying why. (`04cd9fd`, `cde5a42`)
