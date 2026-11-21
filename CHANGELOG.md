# Changelog

Every change since the Zecathon submission, newest first. Each fix adds its entry here in
the same commit.

- The tag `zecathon-final` (October 28, 2026) is the submission, exactly as submitted.
- `nu7` (tag `zecathon-nu7`) is the submission plus only the SDK update for NU7.
- Work happens on `dev`. `main` holds releases: tested versions of `dev`, each with a tag.
  Until the first one is merged, `main` is still at `zecathon-final`.
- There are no version numbers yet, so each entry names its commits. Dates are the commit
  dates as git records them.

## 2026-11-21

### Security
- **Clean-up that can't be undone waits until the chain's time and the phone's clock
  agree.** Since November 19 the app's clock is the time in the newest block the wallet has
  scanned, and block times come from the light server. A server reporting times 22 or more
  days ahead (wrong, or lying) made the weekly prekey rotation drop every prekey already
  handed out, which ends all unused invites, and made the app give up at once on a
  transaction it couldn't read yet. Both steps now run only while the chain's time and the
  phone's clock are within a day of each other, and so does making an invite, which rotates
  prekeys first. When they aren't, nothing is dropped, a new invite says why it can't be
  made, and the chat list says that the phone's date and the network's time don't match.
  Messages still go out on the chain's time, so the notice says they may not arrive. If both
  clocks are wrong the same way, clean-up runs as before. Found by a November 20 review.
  2 new tests. (`331e76a`)
- **Zignal's copy is cleared at the next unlock after a trip to the Home Screen.** In an
  iPhone test on November 19, an invite copied in one profile could still be pasted in the
  other after going to the Home Screen and unlocking with the other PIN. An iPhone test on
  November 21 found why: while Zignal is in the background, the iPhone changes the
  pasteboard's change count by itself (up by 2 on every trip), and the unlock took that for
  something copied since and left Zignal's copy. The Lock button and the next unlock now
  clear the pasteboard whenever Zignal's last copy may still be there, within its 60
  seconds, whatever the count says. So something copied elsewhere within those seconds is
  cleared too. Going to the background still keeps the copy, so it can be pasted into
  another app. 2 tests changed. (`331e76a`)
- **Every unlock takes at least 0.75 seconds from the accepted PIN to the profile showing.**
  Opening a profile takes longer the more it holds, and a panic unlock saves the profile
  files once more, so the time an unlock took could hint at which profile opened or that a
  wipe ran. The minimum covers both as long as opening stays under it. That hasn't been
  measured on an iPhone with a large profile yet; Debug builds print the time. From a
  November 18 review. (`331e76a`)

### Fixed
- **A chat's first messages say "sent, waiting for a first reply", not "delivered".**
  "Delivered" means the transaction is in a block. While nothing from the contact has been
  read in a chat, that doesn't show their phone could read it: an invite that was used
  before, both people scanning each other's invite, and an invite from a profile restored
  since all look the same from this phone. After the first reply, messages say "delivered"
  as before. From a November 18 review. 1 new test. (`331e76a`)
- **A profile whose file isn't on the phone asks when its wallet was created.** A profile's
  file holds its wallet's date, and phone backups never hold that file, so after a backup was
  restored a profile opened empty and its wallet started at the chain tip: its funds looked
  gone. The profile still opens empty (chats can't come back), and above the wallet it asks
  for the wallet's block height or the date it was created; the wallet starts once one is
  given (or neither: October 1, 2026) and looks for its funds from there. Found by a
  November 18 review. 2 new tests. (`4679be2`)
- **A restore with nothing entered starts at October 1, 2026, not today.** A restore that kept
  the screen's date scanned from the day before and didn't show funds received earlier. No
  wallet made in Zignal is older than October 2026; an earlier date can still be picked.
  1 new test. (`4679be2`)
- **A message or a chat start that couldn't be saved leaves the chat as it was.** The chat's
  keys moved on before the save, so when saving failed (a full disk, say) the next message
  went out on keys the contact didn't expect, or, after "Start over", on a chat the contact
  never got, until the app locked. The chat is now put back the way it was. Found by two
  November 18 reviews. 1 new test. (`4679be2`)

### Added
- **A profile that came back without its chats says how to reach contacts again.** A
  recovery phrase brings back the wallet and the identity, not chats, and contacts' phones
  keep sending on the old chats: their messages show "delivered" there and can't be read
  here. Until the profile has a contact, its chat list now says that one of the two has to
  scan a new invite from the other (a contact who scans is asked to start the chat over).
  From a restore test on November 20. (`331e76a`)
- **Restore from a block height or a date.** The restore screen and the question above take a
  block height, a date picked on a wheel, or both; with both, scanning starts from the earlier
  one. A height must be a whole number from 419,200 (Sapling) up and not past the chain's
  end; the wallet starts one block before it, so funds in that very block are found. The
  restore screen says in red that restoring isn't advised: Zignal is meant to start with new
  profiles, and the panic PIN can't erase a copy of the words kept in another app. Both
  screens say in red that only funds from that point on show. 2 new tests. (`4679be2`)
- **Restore the real profile, the decoy, or both.** The restore screen asks which messenger
  profile to bring back: PIN 1 (the unlock PIN, the real profile), PIN 2 (the duress PIN, the
  decoy), or both, each from its own 24 words. A profile that isn't restored starts new; the
  same phrase for both is refused. Before, a phrase always became the real profile and the
  decoy always started new. Chats don't come back. 2 new tests. (`4679be2`)

### Repository
- **License: AGPL-3.0-only from this commit.** Zignal's own code (everything except
  `vendor/`) was under the MIT license or the Apache License 2.0. `LICENSE` now holds the GNU
  Affero General Public License, version 3; `LICENSE-MIT` and `LICENSE-APACHE` are removed,
  and the two Rust crates' `license` fields say `AGPL-3.0-only`. Whoever shares Zignal's
  code, changed or not, must pass on their source under the same license. Versions already
  published (the tags `zecathon-final` and `zecathon-nu7`, the `nu7` branch, and all commits
  up to `1341797`) stay under MIT or Apache-2.0. The SDK in `vendor/` keeps its MIT license.
  No code changes. (`5bb6e53`)

### Documentation
- README: screenshots of the restore screen (which profile comes back, a block height or a
  date), of a restored profile's notice on its chat list, and of the warning before a chat
  starts over, as the contact sees it. Only their pixels: no EXIF, colour profile or other
  hidden data, and no status bar.
- README, CHANGELOG, SECURITY.md and the SDK's `ZIGNAL-PATCHES.md` no longer depend on the
  branch they are read on: the Zecathon submission is named by its tag (`zecathon-final`),
  `main` is described as holding tagged releases of `dev`, the README's "This branch
  (`dev`)" section is now "Since the Zecathon submission", and the SDK's five later changes
  are headed "after the Zecathon submission" instead of "`dev` only". The License section,
  the license entry and its row in the README name earlier versions by tag and commit. Also
  in the README: the light server as the source of the chain's time; a contact who restored
  their profile; the SDK's five changes since the submission, not four (the fifth reads the
  newest scanned block's time); tests through November 20; `basic-toml` and `bincode` 1.3.3
  in `zkw-ffi` marked unmaintained; what Debug builds print; the camera staying on after a
  scan until the Add contact screen closes, and turning off camera access when not scanning;
  and the commits of the license change and the restore changes. (`331e76a`)
- README, from the November 18 reviews: what a restored phone backup brings back; an edited
  copy of a used invite isn't recognized as used; a server may link a wallet's syncs by where
  each one resumes; about 106 guesses a day with the wrong-PIN wait, not 100; the primitives'
  crates are no longer all called audited; the tests need an iOS 27 Simulator or iPhone;
  `bincode` and `paste` in the SDK are marked unmaintained; the test list. A comment in the
  privacy manifest no longer names a script that isn't in the repository. (`4679be2`)

## 2026-11-19

### Security
- **Copies expire after 60 seconds, the next unlock can find Zignal's copy after the app
  was ended, and invites and addresses can be shared without the pasteboard.** Copies expired
  after 5 minutes. The mark that tells the next unlock which pasteboard item is Zignal's own
  lived only in memory, so if the app was ended in the background (by iOS or by swiping it
  away) the next unlock, with any PIN, left the copy there for the other profile to paste.
  The mark is now also kept in the Keychain (this device only): the pasteboard's change count
  and the expiry time, never the text, removed at the next unlock or lock. **Known gap:** in
  an iPhone test on November 19, the next unlock still left the copy after a trip to the Home
  Screen (the cause isn't known yet); the Lock button removes it, and iOS removes it after 60
  seconds. Share invite and Share address send an invite or an address straight to the app
  picked, without the pasteboard; the share sheet has no Copy. Found by two November 18
  reviews. 3 new tests. (`1341797`)

### Fixed
- **Messages and invites run on the chain's clock, not the phone's date.** The sending
  phone picked each message's daily conversation tag from its own clock, while the contact
  reads it at its block time, so a phone whose date was 2 or more days off sent messages
  nobody could read, shown as delivered; prekeys (and so invites) were stamped with the
  phone's date too, so one open with the date weeks ahead could stop every invite already
  handed out. Messages, invites, prekey rotation and retries now use the time of the newest
  block the wallet has scanned; until the wallet has nearly caught up with the network,
  sending and making an invite wait ("still catching up"). A prekey stamped more than a day
  ahead is replaced. The Zcash SDK gets `latestScannedBlock()` to read that time from the
  wallet database. Found by a November 18 review. 3 new app tests, 1 new core test. (`319bc3e`)

### Documentation
- README: `dev`'s tests through November 18, the day of the fee change at block
  3,590,000 (November 19), the dependency advisories as of November 17 (`chrono` and
  `humantime` unmaintained), and the app icon's commit. (`64880e5`)

## 2026-11-18

### Added
- **An app icon:** two hands forming a Z around a globe, white on black, 1024 x 1024
  with only its pixels (no EXIF, colour profile or other hidden data). TestFlight and
  the App Store need one. (`e40bd43`)

### Documentation
- README: TestFlight under Try it (private testing by invitation first); post-quantum
  protection for every message moved up the roadmap. (`e40bd43`)

## 2026-11-17

### Security
- **Unlocking no longer earns wrong-PIN tries back.** Every successful unlock, with any of
  the three PINs, reset the wrong-PIN count, so someone who knew the duress PIN could keep
  guessing, unlocking the decoy between tries, and never reach the wait. Every PIN is still
  counted before it's checked; one that opens a profile now takes back only its own count.
  The count starts over after 2 hours with no wrong PIN, on the boot clock (a restart starts
  the 2 hours over); the lock screen says so under the countdown. 5 wrong PINs are free, then
  the wait doubles from 30 seconds to 1 hour as before. A counter that can't be read counts as
  no free tries left, instead of starting over with all of them.
  Found by Zignal's own pressure test (round 4). 4 new tests. (`e62efe0`)
- **What Zignal copied leaves the pasteboard at lock and unlock.** Copied message text,
  invites and addresses stayed on the pasteboard after the app locked, until they expired
  after five minutes, so they could be pasted into the other profile or read by any app; the
  decoy even showed "Invite found" for an invite copied in the real profile. The Lock
  button and every unlock now remove Zignal's copy, unless something else was copied since.
  Going to the background keeps it, so an invite can still be pasted into another app.
  Found by a November 15 review. 1 new test. (`3f731ac`)

### Fixed
- **A send check that's taking long says so.** After a lock, an interrupted send shows
  "Checking whether it went out…" until the wallet has caught up with the network; with no
  server reachable, that never ended and looked stuck. After a minute it now says that the
  wallet hasn't caught up yet and that Zignal keeps trying. Found by the same review. 1 new
  test. (`3f731ac`)
- **The first message's fee text** says about 0.00025 ZEC (its four memos and the change
  make five actions), not 0.0002. (`3f731ac`)

### Documentation
- README: the wrong-PIN tries, the test list and the roadmap. (`e62efe0`)
- README: three screenshots of the invite screens: only one of you scans, an invite works
  once, and a used invite refused. (`8a8fac4`)
- README: the browser demo under Try it. (`3f731ac`)
- README: the network fee change at block 3,590,000; what the pasteboard keeps; that a server
  may link Tor fetches to a sync by timing; Zebra's built-in wallet server; what a chat's
  first message shows to a viewing key; that an unused invite's ID doesn't expire; a message
  sent again days later; the test list and the roadmap. A code comment on where the profile
  key comes from. (`3f731ac`)
- README: a screenshot of the warning before a chat starts over. (`96bc7ea`)

## 2026-11-15

### Security
- **The recovery phrase screen treats the panic PIN as a wrong PIN.** The panic PIN opens the
  decoy too, so on that screen it showed the decoy's recovery phrase without wiping anything:
  someone holding the duress PIN could find the panic PIN there, safely, and then avoid it on
  the lock screen. Found by Zignal's own pressure test. 1 new test. (`e7bd418`)

### Fixed
- **A restore starts scanning at the beginning of the day before the date picked.** The date
  kept the time of day the restore screen was opened at, and the SDK starts from the newest
  checkpoint before that moment, so a checkpoint made later on the picked day could have
  skipped the wallet's first transactions. It matters now that the SDK has a recent
  checkpoint. At most a day more to scan. 2 new tests. (`5e795ee`)
- **An invite used before is refused.** An invite works only once: the inviter's phone
  refuses a second start from it. Accepting it again replaced the chat on this phone with one
  the contact never got, so neither side could read the other any more, and neither phone
  showed it. It happened in testing. Each accepted invite's fingerprint (SHA-256) is kept in
  the profile's sealed data. (`e7bd418`)
- **A new invite from an existing contact asks first** ("Start over") and says what it does.
  If the contact's first message has already arrived, scanning their invite asks first too.
  5 new tests. (`e7bd418`)

### Changed
- **Default servers from three operators:** zec.rocks (`zec.rocks`, `na.zec.rocks`,
  `eu.zec.rocks`), Stardust (`us.zec.stardust.rest`, `eu.zec.stardust.rest`) and Cake Wallet
  (`zec-node.cakewallet.com`). `lwd1` and `lwd2.zcash-infra.com` no longer exist and are
  gone from the list. Only the first server is used, and it's still `zec.rocks`, so nothing
  changes for a profile that keeps the defaults; Restore defaults brings the new list. 1 new
  test. (`5e795ee`)
- **The invite screens say that only one person scans.** If both people scan each other's
  invite before either phone has read the other's first message, the chat breaks on both
  phones; a fix needs the next invite format. (`e7bd418`)

### Added
- **A recent mainnet checkpoint** in the SDK: block 3,565,000 (November 12, 2026, after NU7),
  with the Ironwood tree, fetched from two separate operators and matched field by field. A
  wallet restored with a date of November 14, 2026 or later scans from it instead of from
  block 3,390,000. 1 new test checks the app ships it. (`5e795ee`)

### Documentation
- README, from an outside review of `775e08d`: what a leaked viewing key still shows (each
  memo's short header: that Zignal is in use, a day's messages grouped by chat, how long each
  one is, when a chat started), and choosing the three PINs several digits apart. (`5e795ee`)
- README, brought in line with the code: a successful unlock resets the wrong-PIN count; a
  panic unlock saves the profile files once more than other unlocks before the decoy shows
  (the 2026-11-12 entry said it takes as long as any other); files written back after a wipe
  are deleted at a later unlock; an older install keeps using its unsealed vault, with no
  notice, while the Secure Enclave seal can't be made. (`5e795ee`)
- README and `ZIGNAL-PATCHES.md`: the RustSec advisories published after November 4
  (`libsqlite3-sys`, RUSTSEC-2026-0459; `rustix`, RUSTSEC-2026-0486). README: the tests up
  to November 14, and build commands that each run in their own folder. This changelog says
  that its dates are the commit dates as git records them. (`5e795ee`)
- README: the default servers, the SDK's four changes on `dev`, the test list, and the roadmap
  entry for faster restores. (`5e795ee`)
- README: starting a chat (only one person scans), the panic PIN on the recovery phrase
  screen, the test list. (`e7bd418`)

## 2026-11-14

### Security
- **The Rust core's build keeps the build machine out of the library.** Rust records source
  paths for error messages, and on a Mac they include the builder's account name, which would
  end up in the app. `zkw-ffi/build-ios.sh` now removes them and stops if the library still
  contains the home folder or account name, as the SDK's build already did. (`f8b3881`)

### Added
- **A privacy manifest** (`PrivacyInfo.xcprivacy`), which Apple requires before an upload: the
  app tracks no one, collects no data, and uses its own settings (`UserDefaults`), the
  dates of its own files, and the free storage space (`statfs`, used by libraries linked
  into the app).
  1 new test checks the app ships it. (`f8b3881`)

### Documentation
- README: TestFlight isn't public yet; private testing comes first, then a public link. (`f8b3881`)

## 2026-11-12

### Security
- **A panic unlock takes as long as any other.** Finishing a silent wipe (waiting up to 15
  seconds for a wallet that is still stopping, then deleting the wiped profile's files) ran
  before the decoy appeared, so a panic unlock, or a duress unlock that finished an
  interrupted wipe, could be told apart by its delay. The clean-up now runs once the decoy is
  on screen, holding only the decoy's wallet alias and file name. Found by an outside review. (`775e08d`)
- **Finishing a wipe renames nothing.** The wiped profile's file was replaced by filler under
  a new name, which two listings of the app's files could show. It's now overwritten under its
  own name, as every save rewrites every file. Found by an outside review. 2 tests updated. (`775e08d`)
- **A wipe counts as finished only after two clean unlocks.** One look at the wallet folder
  could miss a wallet that wrote its files late; the decoy's sealed data now counts unlocks in a
  row that find nothing left. Hidden system names in the wallet folder don't count as leftovers.
  1 new test. (`775e08d`)
- **The wallet no longer sends its transparent addresses.** On every sync the SDK asked the
  server about all of the wallet's transparent addresses (unspent outputs, and transactions
  involving them), directly even with Tor on: the same identifier of the wallet each time,
  across IP addresses, VPN exits and Tor. Zignal uses shielded addresses only; both queries are
  skipped in the vendored SDK (listed in `vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md`).
  ZEC sent to one of the wallet's transparent addresses isn't shown (the app never gives one
  out). (`775e08d`)
- **Storing the vault is read back before an older copy is deleted**, as moving an older item
  already was. (`775e08d`)

### Documentation
- README: the network privacy section is corrected. With Tor on, syncing (blocks, tree states,
  subtree roots) still connects directly, and until now the wallet's transparent addresses were
  sent too. The duress and panic notes describe the clean-up after the decoy is on screen. (`775e08d`)

## 2026-11-11

### Security
- **Profile files are written in a random order.** Each save writes every profile file again,
  and each write makes a new file, so writing the saved profile's file first let file IDs show
  which profile was in use. 1 new test. (`487ba86`)
- **The recovery words appear only once the screen capture state is known.** The words and
  the restore field start hidden, and the capture watcher covers the whole recovery phrase
  screen, so a recording, mirroring or screen sharing that's already running can't catch the
  words in its first frame. (`487ba86`)
- **Changing the server or Tor can't restart a locked wallet.** A server switch validated the
  new server, then restarted the wallet, even if the profile had locked meanwhile, so a
  stopped wallet could sync again and write its files, including after a panic wipe had
  deleted them. The vendored SDK's `switchTo` no longer restarts a synchronizer the app has
  stopped (a patch listed in `vendor/zcash-swift-wallet-sdk/ZIGNAL-PATCHES.md`), the app stops
  the wallet again if it locked during the change, and a panic wipe waits for such a change
  like it waits for a wallet that is stopping. 1 new test. (`487ba86`)
- **Copying stays on this phone.** Message text and the wallet address could be selected, and
  the system's Copy put them on the general pasteboard: Universal Clipboard to other Apple
  devices, no expiry. Selection is off; a Copy action (touch and hold a message) uses the same
  local, 5-minute clipboard as invites. (`487ba86`)
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
  and recordings, and local tooling folders. No file in the repository matched these. (`487ba86`)

### Documentation
- New README section "Network privacy: Tor, a VPN or your own server": what the server sees
  with Tor off and on, a comparison with Zodl's Oblivious HTTP relay, and how to use a VPN
  (kill switch, choosing an audited no-logs provider, shared addresses, what a VPN doesn't
  do, and a VPN with Tor as the strongest setup today). The roadmap adds asking ZODL about its
  relay. The README also describes the smaller fixes above. (`487ba86`)
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
