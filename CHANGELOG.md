# Changelog

Every change on the `dev` branch since the Zecathon submission, newest first. Each fix adds
its entry here in the same commit.

- `main` (tag `zecathon-final`, October 28, 2026) is the submission and stays as submitted
  until judging ends.
- `nu7` (tag `zecathon-nu7`) is the submission plus only the SDK update for NU7.
- There are no version numbers yet, so each entry names its commits. Dates are commit dates.

## 2026-11-11

### Security
- **Profile files are written in a random order.** Each save writes every profile file again,
  and each write makes a new file, so writing the saved profile's file first let file IDs show
  which profile was in use. 1 new test.
- **The recovery words appear only once the screen capture state is known.** The words and
  the restore field start hidden, and the capture watcher covers the whole recovery phrase
  screen, so a recording, mirroring or screen sharing that's already running can't catch the
  words in its first frame.
- **Changing the server or Tor can't restart a locked wallet.** A server switch validated the
  new server, then restarted the wallet, even if the profile had locked meanwhile, so a
  stopped wallet could sync again and write its files, including after a panic wipe had
  deleted them. The vendored SDK's `switchTo` no longer restarts a synchronizer the app has
  stopped (a patch listed in `vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md`), the app stops
  the wallet again if it locked during the change, and a panic wipe waits for such a change
  like it waits for a wallet that is stopping. 1 new test.
- **Copying stays on this phone.** Message text and the wallet address could be selected, and
  the system's Copy put them on the general pasteboard: Universal Clipboard to other Apple
  devices, no expiry. Selection is off; a Copy action (touch and hold a message) uses the same
  local, 5-minute clipboard as invites.
- **A panic wipe that was cut short is finished the next time the decoy opens.** The panic
  PIN now records in the decoy profile's own sealed data that a wipe is under way, and clears
  the record only once the real profile's file and wallet files are confirmed gone. If the
  app is closed or the phone switched off before then, the next unlock of the decoy, with the
  duress or the panic PIN, finishes the wipe. Before, the real wallet's database stayed on the
  phone until the panic PIN was entered again. A wipe cut short also ends with the usual two
  profile files. 3 new tests. (`0d6a1fc`)
- **Every unlock stores the PIN vault again**, under a new seal, so its Keychain item changes
  on every unlock and its change date no longer marks a panic wipe. 1 new test. (`0d6a1fc`)
- **The Zcash SDK's one setting per wallet moves out of the app's preferences.** The SDK
  recorded the app version for which it last repaired a wallet's notes as
  `ud_fixWitnessesLastVersionCall_c_<alias>` in the app's preferences, which go into device
  backups and outlive the wallet's files, so they kept one entry for every wallet the app had
  opened. The record is now a file in the wallet's own folder, which isn't backed up and is
  deleted with the wallet. The app deletes the old entries each time it starts. The first time
  each wallet opens after the update, the SDK runs that repair once more. A patch to the
  vendored SDK, listed in `vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md`. 1 new test. (`0d6a1fc`)
- **The PIN vault is sealed by the iPhone's Secure Enclave**, and so is the device key for
  the profile files. Both are stored in the Keychain encrypted to a P-256 key that never
  leaves the Secure Enclave (ECDH with a fresh ephemeral key, HKDF-SHA256, AES-GCM). A copy
  of the Keychain taken off the phone can't be opened, so the PINs can no longer be guessed
  offline from it. An existing install seals its vault the first time it opens after the
  update and its device key at the first unlock, without asking for a PIN; each old copy is
  deleted only after the sealed one has been read back and opened. Each setup makes a new
  key. Release builds refuse to set up without a Secure Enclave. New file
  `Core/DeviceSecrets.swift`; 10 new tests. (`adbf62f`)
- **The wrong-PIN wait no longer follows the clock.** It's measured on
  `CLOCK_MONOTONIC_RAW` (the clock behind Swift's `ContinuousClock`), which keeps counting
  while the phone sleeps and can't be set. Changing the date or time doesn't shorten the
  wait; a restart can start it over but never shortens it. A wait saved by an older version
  starts over once. 2 new tests. (`adbf62f`)

### Repository
- `.gitignore` also keeps out wallet database copies (`*.db`, `*.sqlite` and their journal
  files), logs and traces, key files (`*.key`, `*.pem`, `.env*`), phone screenshots, photos
  and recordings, and local tooling folders. No file in the repository matched these.

### Documentation
- New README section "Network privacy: Tor, a VPN or your own server": what the server sees
  with Tor off and on, a comparison with Zodl's Oblivious HTTP relay, and how to use a VPN
  (kill switch, choosing an audited no-logs provider, shared addresses, what a VPN doesn't
  do, and a VPN with Tor as the strongest setup today). The roadmap adds asking ZODL about its
  relay. The README also describes the smaller fixes above.
- The README describes how a wipe that was cut short is finished, the vault stored again on
  every unlock, and where the SDK's setting is kept. (`0d6a1fc`)
- The README's security notes describe the seal and the new wait, and what's still possible
  with code running inside Zignal on an unlocked phone. The known limitations about a copy of
  the Keychain and about the clock are gone. (`adbf62f`)

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
  vault, and the wrong-PIN wait that follows the clock. (`31280e6`)
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
