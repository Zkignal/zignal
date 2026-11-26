# Notes for Zcash developers

What building Zignal (a messenger on shielded memos, iOS, Zcash Swift SDK 3.0.0) showed us
about the light-wallet stack. Written for people who build wallets and apps on Zcash. Each
note says what we saw, where the code is, and what we don't know.

Corrections are welcome: open an issue, or see [SECURITY.md](../SECURITY.md) for anything
sensitive. The text of these notes may be reused freely; the code they point to keeps its own
licence (see [LICENSE](../LICENSE) and `vendor/`).

1. [How crowded shielded blocks are](#1-how-crowded-shielded-blocks-are-measured-on-mainnet)
2. [The light server sets your clock](#2-the-light-server-sets-your-clock)
3. [What Tor covers in the Swift SDK](#3-what-tor-covers-in-the-swift-sdk-and-what-it-doesnt)
4. [Swift SDK 3.0.0 after NU7](#4-swift-sdk-300-after-nu7)
5. [Binary data in memos](#5-binary-data-in-memos)

## 1. How crowded shielded blocks are (measured on mainnet)

**Why it matters.** To read a memo, a light wallet asks its server for the whole transaction
by ID (`GetTransaction`), so the server learns which transactions a wallet cares about. Every
fix for that (decoy fetches, fetching in fixed rounds, private retrieval) depends on how many
other transactions there are to hide among. We couldn't find the numbers, so we measured.

**How.** A Debug-only counter in our copy of the SDK counts, for each batch of blocks the
wallet syncs, the transactions and their Ironwood action counts, from the compact blocks the
wallet downloads anyway. No transaction IDs, addresses or heights; nothing is stored or sent.
See "Measurement" in
[`ZIGNAL-PATCHES.md`](../vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md).

**One sync on November 25, 2026: 5,411 blocks (about 1.6 days at 25 seconds a block).**

| Per 100 blocks (53 full batches) | Median | Lowest | Highest |
|---|---|---|---|
| Transactions in the compact blocks | 68 | 16 | 173 |
| Of those, with Ironwood actions | 62 | 15 | 166 |

| Ironwood actions in a transaction (3,793 transactions) | Share |
|---|---|
| 1 | 13.9% |
| 2 | 65.8% |
| 3 or 4 | 15.6% |
| 5 to 8 | 4.4% |
| 9 to 16 | 0.3% |
| 17 or more | 0.1% |

- That is about 0.6 Ironwood transactions per block. ZecHub's count for November 15 to 22
  (13,358 Ironwood transfers, in its
  [digest of November 22](https://zechub.substack.com/p/zcash-ecosystem-digest-november-22nd))
  works out to about 0.55 per block, so the two agree.
- Two full transactions fetched during the sync were 9,166 and 12,322 bytes.
- In a 100-block batch, transactions with 3 or more actions: median 13, lowest 1. With 5 or
  more: median 2, lowest 0.

**What we take from it.**
- A single block is no crowd: many blocks hold no shielded transaction at all. Decoys have to
  come from a batch of blocks, or several.
- Two-action transactions are the crowd. A transaction with many actions (for us, a long
  message split over several memos) has almost nothing that looks like it, so decoys must be
  matched by action count, in ranges, or it stands out anyway.
- A fixed number of fetches after every sync, real ones first and decoys to fill, also hides
  whether anything arrived. The idea is from
  [Blindfetch](https://github.com/YASASWIP012/blindfetch), a Zecathon entry; it needs no
  server change.

**Limits.** One wallet, one window of 1.6 days, three weeks after NU7. Two batches were
counted twice (a re-scan), which doesn't move the medians. Treat it as an order of
magnitude and measure again before relying on it.

## 2. The light server sets your clock

**What we saw.** A light wallet takes two things from its server unchecked that an app can
easily mistake for facts:
- **Block times.** A compact block carries a height, its hash, the previous hash and a time.
  The wallet checks that each block points at the one before it. Nothing in there lets a
  phone check proof of work, and nothing checks the time.
- **Where a new wallet starts.** For a new wallet the SDK asks the server for the chain tip
  and starts a little below it (`Initializer.swift`). A server can start a new wallet at any
  height it likes.

**Why it matters.** Anything an app times by block time can be moved by the server: expiry,
key lifetimes, replay windows, "sent on" dates. In Zignal a message carries a tag for its
day, prekeys live 21 days and replay records 30. A server that dated one block weeks ahead
could end every invite a user had handed out and empty the replay records.

**What we tried first, and why it wasn't enough.** Comparing with the phone's clock: phones
with a wrong date are common, they then stop working, and a phone wrong the same way as the
server hides it.

**What Zignal does now: a clock from block height.** `HeightClock` in
[`WalletSupport.swift`](../ios/Zignal/Zignal/Core/WalletSupport.swift), tests in
`HeightClockTests`:
- Anchors: the (height, time) pairs of checkpoints the SDK ships. Never anything a server
  said.
- Spacing: 75 seconds a block, 25 from NU7 (block 3,543,405, ZIP 218). Between two anchors
  the difference between that and the real time is spread evenly (plain spacing was 16 to 19
  hours off over five months).
- Measured: 6 minutes off, 13 days after the newest anchor.
- A block time more than a day from its height's time is replaced by the height's and the
  user is told. Steps that can't be undone wait until the two match.
- A block the clock can't date (below its oldest anchor, without a height, or with a height
  no chain has) gives no time at all.
- A test fails when an SDK update ships a newer checkpoint, so the anchors move with it.

**What it doesn't solve.**
- A server that serves a whole fake chain, with heights to match, isn't caught.
- A network upgrade that changes the block spacing needs a new row in the table.
- A server off by less than a day goes unnoticed.

**What would be better.** A way for a wallet to check a server's word about the chain.
[Zaino 0.11.0-rc1](https://forum.zcashcommunity.com/t/zaino-0-11-0-rc1-a-new-home-at-umbriel-systems-and-a-big-step-forward/59544)
adds experimental calls for block headers and for a proof that a block is in the chain
(`GetHistoryProof`). We haven't used them yet. Asking a second server for its
tip is a cheaper partial check.

## 3. What Tor covers in the Swift SDK, and what it doesn't

Read from the source of SDK 3.0.0 as Zignal builds it. With Tor turned on:

| Request | Goes over Tor? |
|---|---|
| Sending a transaction | Yes |
| Fetching a transaction by ID (memos, status) | Yes, one circuit per transaction ID |
| Server check (`GetLightdInfo`), chain tip | Yes |
| Tree state when a wallet is created | Yes |
| Downloading compact blocks | **No, direct** |
| Subtree roots, the scanner's tree state | **No, direct** |
| The mempool stream (new transactions, live) | **No, direct**, open while the wallet runs |
| Transparent address history and UTXOs | **No, direct** (Zignal no longer asks, see below) |

- Upstream knows: [zodl-inc/zodl-swift-wallet-sdk#14](https://github.com/zodl-inc/zodl-swift-wallet-sdk/pull/14)
  says block download, subtree roots and the mempool stream stay direct because the Rust
  connection they use has no Tor path. It was closed in October 2026 in favour of another
  implementation. Zodl's wallet and its newer SDK send requests through Oblivious HTTP relays;
  our README's [Network privacy](../README.md#network-privacy-tor-a-vpn-or-your-own-server)
  section compares the two.
- So with Tor on, a server still sees the phone's IP address when it syncs and for as long
  as the app is open. It doesn't see the IP address on the fetches, but it can often link
  them by timing: the wallet fetches a transaction right after it downloaded, directly, the
  block that holds it.
- **A wallet identifier to look for in your own app:** until we removed it, every sync sent
  all of the wallet's transparent addresses in one direct request. That lets a server
  recognise the same wallet across IP addresses, VPNs and Tor. Zignal uses shielded
  addresses only and no longer asks ("no transparent-address queries" in
  [`ZIGNAL-PATCHES.md`](../vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md)).
- If your app has a Tor switch, say next to it what it doesn't cover. Ours is in the
  README's Network privacy section, in [PRIVACY.md](../PRIVACY.md) and on the Network screen.
- **A Tor library version to check.** Zodl reports
  ([zodl-inc/slipstream#37](https://github.com/zodl-inc/slipstream/pull/37)) that since
  November 15, 2026 the Tor network's consensus sometimes lacks its `bandwidth-weights` line,
  and that Arti 0.43 then gives every guard a weight of zero and can't build a circuit; Arti
  0.44 picks one at random instead. Our build of the SDK's Rust layer is on Arti 0.43, so
  with Tor on, sending and fetching can stall until the line is back. We haven't confirmed
  the cause ourselves. Moving to 0.44 is our next change to the SDK copy; if yours is on
  0.43, look at it too.

## 4. Swift SDK 3.0.0 after NU7

**Start somewhere else if you start today.** SDK 3.0.0 belongs to the old
`zcash-swift-wallet-sdk` line. Its
[final release](https://github.com/zcash/zcash-swift-wallet-sdk/releases/tag/4.0.0) (October
2026) says support ends when NU7 activates and development continues in
[Zodl's Swift Wallet SDK](https://github.com/zodl-inc/zodl-swift-wallet-sdk) (8.1.0 on
November 18, 2026). Check its licence against how you distribute your app. Zignal is still on
its own patched copy of 3.0.0; this note is about that copy.

The prebuilt Rust library of SDK 3.0.0 doesn't know NU7's mainnet height: past block
3,543,405 it computes the wrong consensus branch, syncing stops and transactions would be
built wrong. Zignal builds that library from source on librustzcash's NU7 releases instead.
Everything is in [`ZIGNAL-PATCHES.md`](../vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md)
and under `vendor/` (MIT, as upstream):
- **The NU7 build:** the crate versions, the source changes the new crate APIs needed, and a
  build script that keeps the build machine's file paths out of the library.
- **`stop()` could be undone by the SDK itself**, and stopped wallets kept old mempool
  watchers running. Both matter for any app that locks: a "stopped" wallet kept syncing and
  could write its files again. Reported upstream as
  [zcash/zcash-swift-wallet-sdk#2012](https://github.com/zcash/zcash-swift-wallet-sdk/issues/2012).
- **A record the SDK keeps per wallet in the app's preferences** (which go into device
  backups) moved into the wallet's own folder. Worth a look if your app holds more than one
  wallet, or promises that deleting one leaves nothing behind.
- **RustSec advisories in the SDK's lock file**, each with why it does or doesn't matter for
  a wallet, and which ones a compatible update clears.

## 5. Binary data in memos

- **Start a binary memo with `0xFF`.** ZIP 302 reads a memo whose first byte is `0xF4` or
  below as UTF-8 text. Our first format began with two ASCII letters, so wallets and the SDK
  took it for text, found it wasn't valid, and rejected it. With `0xFF` in front (arbitrary
  data) the SDK hands the other 511 bytes back untouched.
- **Several memos in one transaction** work through a ZIP 321 payment request with one
  zero-value output per memo. The fee follows the number of actions (ZIP 317), so it shows
  roughly how many memos a transaction carries.
- **Pad every memo to the full 512 bytes with random bytes**, so a short one doesn't look
  different inside the note encryption.
- **Give each contact its own address.** The SDK makes Orchard-only unified addresses on
  request, so contacts can't compare notes and link you.
- Our envelope is in [`zkw-core/src/envelope.rs`](../zkw-core/src/envelope.rs), with a Python
  reference and test vectors in [`zkw-ref/`](../zkw-ref).
