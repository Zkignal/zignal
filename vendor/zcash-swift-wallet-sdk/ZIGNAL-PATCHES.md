# Changes made by Zignal to zcash-swift-wallet-sdk 3.0.0

This folder is ZcashLightClientKit as released at tag `3.0.0` of
https://github.com/zcash/zcash-swift-wallet-sdk (MIT License, see `LICENSE`), exported with
`git archive 3.0.0 Package.swift LICENSE README.md Sources`, plus the SDK's Rust layer
(`Cargo.toml`, `rust/`) and three files from `BuildSupport/` of the same tag. Zignal builds
`libzcashlc` from that Rust source instead of linking the prebuilt upstream binary.

Only the changes below differ from upstream. Everything else is byte-for-byte the release.

## NU7: `libzcashlc` built from source on the NU7 crates

**Problem.** The NU7 network upgrade activates at mainnet block 3,543,405 (testnet 4,465,026).
The prebuilt `libzcashlc` of SDK 3.0.0 is built on a librustzcash revision of August 7, 2026,
which has no NU7 mainnet height. After activation it computes the wrong consensus branch ID: the
SDK's server check (`ValidateServerAction`) then stops syncing, and transactions would carry the
wrong branch ID. ECC's SDK has reached end of life and gets no NU7 release; librustzcash's NU7
releases came out on October 21-22, 2026.

**Changes.**
- `Cargo.toml`, `Cargo.lock`, `rust/`: the Rust layer of tag 3.0.0 (version `3.0.0-zignal.1`),
  moved to librustzcash's NU7 releases from crates.io: zcash_protocol 0.11, zcash_address 0.14,
  zcash_primitives and zcash_proofs 0.31, zcash_keys 0.17, zcash_client_backend 0.25,
  zcash_client_sqlite 0.23, pczt 0.10, orchard 0.16, sapling-crypto 0.9, rand 0.10. No git
  dependencies.
  - Source updates for the new crate APIs: the system random number generator is now passed as
    `UnwrapErr<SysRng>` (rand 0.10), transaction building takes a clock, unified addresses
    carry a revision, the encoded unified spending key comes back wrapped as a secret, and the
    Sapling key prefixes come from `zcash_keys::constants`. What the library does is unchanged
    apart from NU7 itself.
  - TLS and HTTP/2: `rustls-webpki` 0.103.16, `webpki-roots` 1.0.11, `rustls` 0.23.46 or later
    (RUSTSEC-2026-0285, -0346, -0348, -0349) and `h2` 0.4.16 or later (RUSTSEC-2026-0258).
  - Patch releases with security fixes: `tokio` 1.53.3 (RUSTSEC-2026-0386), and, used by arti,
    the Tor client, `zstd` 0.13.4, `zstd-safe` 7.4.0, `zstd-sys` 2.1.2 (RUSTSEC-2026-0391,
    -0398, -0403, -0410) and `event-listener` 5.4.2 (RUSTSEC-2026-0221).
  - The two remaining RustSec advisories in `Cargo.lock` come in through arti, which Zignal
    leaves off by default, and have no compatible fix: `rsa` (the Marvin attack targets
    private-key decryption; a Tor client only verifies signatures) and `crypto-bigint` (SSH key
    parsing for onion services, which Zignal doesn't use). They clear when arti moves to newer
    versions.
  - EIP-681 parsing and the Orchard-to-Ironwood pool migration are left out; Zignal doesn't use
    them. `rust/src/eip681.rs` and `rust/src/migration.rs` are stubs that
    `Scripts/gen_stubs.py` generates from the upstream files of the same name: same C
    declarations, and each call reports "not supported in this build". About 13,000 lines of
    upstream code are left out.
- The C header that `rust/build.rs` generates (`zcashlc.h`) declares exactly what the 3.0.0
  release's header declares, so the Swift code is unchanged.
- `Package.swift`: links `libzcashlc` from `LocalPackages/` only. There is no fallback to the
  upstream binary, because that one stops working at NU7.
- `Scripts/build-ios-ffi.sh` builds the iPhone and Simulator slices and installs them in
  `LocalPackages/` (git-ignored). It builds for iOS 17.0 and later, the app's minimum, and stops
  if any part of the library needs a newer iOS. It removes the build machine's file paths from
  the library (upstream's release binary contains its builder's home folder path) and stops if
  any remain.
  `BuildSupport/` holds upstream's `module.modulemap`, `platform-Info.plist` and
  `LocalPackages-Package.swift`, unchanged.

**Build** (macOS with Xcode, Rust 1.97 or newer), from this folder:

    rustup target add aarch64-apple-ios aarch64-apple-ios-sim
    ./Scripts/build-ios-ffi.sh

## Fix: `stop()` could be undone by the SDK itself

**Problem.** If `SDKSynchronizer.stop()` lands while a sync is running, cancelling the running
action usually surfaces as a transport error. `CompactBlockProcessor.run()` checks for service
errors before it checks for cancellation, so it resets the context and loops. At the top of the
loop it re-arms the repeating poll timer that `stop()` had just invalidated. That timer later
calls `start()`, and with `ZcashSDK.defaultRetries = Int.max` it keeps doing so. The processor
then syncs (network traffic, database writes) until the process exits, even though the host
app stopped it and released the synchronizer. If the app deleted the wallet's files in the
meantime, the next attempt recreates an empty `data.db` at the same path.

Also, `SDKSynchronizer.stop()` skipped stopping the processor when the status was `.stopped`
or `.disconnected`, which can be true while the poll timer is still armed.

**Changes.**
- `CompactBlockProcessor`:
  - `stopRequested`, set by `stop()` and cleared only by an explicit `start(retry:)`.
  - The poll timer calls a private `startSync(retry:)`, which never clears `stopRequested` and
    re-checks it right before creating the sync task.
  - `setTimer()` does nothing after a stop, and the timer callback returns early after a stop.
  - In `run()`, cancellation (or a requested stop) is handled before the service-error retry.
  - New `stopAndWait()`: stops, then waits for the running sync loop (and, see below, the
    mempool watcher) to exit.
- `SDKSynchronizer`:
  - `stop()` always stops the processor (stopping is idempotent).
  - New public `stopAndWait()`, which Zignal calls when a profile is locked.
- `Package.swift`: test targets removed (the tests are not vendored).

## Fix: stopped wallets kept old mempool watchers running

**Problem.** Every sync start (the poll timer starts one every 10 to 30 seconds) started a new
mempool watcher (`mempoolDetectionTask = Task { await watchMempool() }`) without cancelling
the previous one, and `stop()` cancelled only the newest. The older watchers ran until the
process exited, each with its own open mempool stream to the server. Every mempool
transaction they received went through `resolveMempools`, which opens the wallet database;
if the app had deleted the wallet's files, that recreated an empty `data.db` at the same path.
While a wallet runs, the watchers also pile up: after N sync starts there are N open streams
and every mempool transaction is decrypted N times.

**Changes** (`CompactBlockProcessor` only):
- A sync start creates a watcher only when none is running; `stop()` cancels it and clears it.
- The watcher loop also ends once `stopRequested` is set, and a transaction that arrives after
  a stop is dropped before it reaches the database.
- `stopAndWait()` closes the server connection once the sync loop has exited (which ends the
  open mempool stream), then waits for the watcher to exit. The service reconnects on its next
  call if the processor is started again, as it already does after its own retry path.

Files: `Sources/ZcashLightClientKit/Block/CompactBlockProcessor.swift`,
`Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift`, `Package.swift`,
and this file. Every changed spot is marked `Zignal patch`.

Both fixes are reported upstream: https://github.com/zcash/zcash-swift-wallet-sdk/issues/2012
(the stop issue, and the mempool watchers in a follow-up comment).

## Change: the witness-repair record moves out of the app's preferences (Zignal `dev` only)

**Problem.** Once per app version and wallet, `SDKSynchronizer.prepare` runs a witness repair
and records the version it ran for in `UserDefaults.standard`, under
`ud_fixWitnessesLastVersionCall_<alias>`. Zignal names each wallet with an alias derived from
its profile (`c_<16 hex>`) and keeps the wallet files out of device backups, but the app's
preferences file is in every backup. One key per wallet showed how many wallets had been
opened, and each recorded version showed which app version that wallet last ran under. A
backup taken before a panic wipe and the phone after it showed that a wallet was removed.

**Change.** `WitnessesFixGate` keeps the record in a file, `witnesses_fix_version`, inside the
alias's own general storage folder (`Initializer.generalStorageURL`, which the SDK already
prefixes with the alias, for example `c_<alias>_general/`). That folder sits with the wallet's
other files, out of backups, and goes when the wallet's files are deleted. The decision rules
are unchanged. Zignal removes the old keys from its preferences at launch, so each wallet runs
the repair once more after the update (the repair is idempotent).

Files: `Sources/ZcashLightClientKit/Utils/WitnessesFixGate.swift`,
`Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift`, and this file. Every changed
spot is marked `Zignal patch`. Not on the `nu7` branch.

## Change: a server switch doesn't restart a stopped synchronizer (Zignal `dev` only)

**Problem.** `SDKSynchronizer.switchTo(endpoint:)` validates the new server (a network call
that can take seconds), rebuilds the services, and then calls `start(retry: true)` whenever
the synchronizer is prepared. If the app stopped the synchronizer meanwhile (Zignal stops it
when the profile locks), the switch started it again. A wallet the app had stopped could keep
syncing and writing its files, including after a silent wipe had deleted them.

**Change.** `SDKFlags` gets `stoppedByClient`, set by `stop()` and `stopAndWait()` (through
`sdkStopped()`) and cleared by the client's next `start(retry:)` (through `sdkStarted()`).
`switchTo` restarts only while it's false. The app also stops the wallet again if it was
locked while settings were being applied, and counts that work as a wallet winding down.

Files: `Sources/ZcashLightClientKit/Utils/SDKFlags.swift`,
`Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift`, and this file. Every changed
spot is marked `Zignal patch`. Not on the `nu7` branch.

## Change: no transparent-address queries (Zignal `dev` only)

**Problem.** On every sync, `FetchUTXOsAction` asked the light server for the unspent outputs of
every transparent address of the wallet (`UTXOFetcher`, `listTransparentReceivers`), and
`BlockEnhancer` answered librustzcash's `transactionsInvolvingAddress` requests with
`getTaddressTransactions`. Both use `ServiceMode.direct`, so they leave from the phone's own
IP address even with Tor on. The server received the same list of the wallet's transparent
addresses on each sync: a stable identifier that follows the wallet across IP addresses, VPN
exits and Tor. Zignal uses shielded (Orchard) addresses only and never shows a transparent one.

**Change.** `FetchUTXOsAction.run` skips the fetch and goes straight to the next step.
`BlockEnhancer` drops `transactionsInvolvingAddress` requests before its loop. Transaction
fetches for the wallet's own transactions (`.enhancement`, over Tor when it's on) are unchanged.
Side effect: ZEC sent to one of the wallet's transparent addresses isn't seen by Zignal (the app
never gives one out; restore the words in a full wallet to recover such funds).

Files: `Sources/ZcashLightClientKit/Block/Actions/FetchUTXOsAction.swift`,
`Sources/ZcashLightClientKit/Block/Enhance/BlockEnhancer.swift`, and this file. Every changed
spot is marked `Zignal patch`. Not on the `nu7` branch.
