# Changes made by Zignal to zcash-swift-wallet-sdk 3.0.0

This folder is ZcashLightClientKit as released at tag `3.0.0` of
https://github.com/zcash/zcash-swift-wallet-sdk (MIT License, see `LICENSE`), exported with
`git archive 3.0.0 Package.swift LICENSE README.md Sources`. It links the same prebuilt
`libzcashlc` binary as the upstream release (same URL and checksum in `Package.swift`).

Only the changes below differ from upstream. Everything else is byte-for-byte the release.

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

Reported upstream: https://github.com/zcash/zcash-swift-wallet-sdk/issues/2012
