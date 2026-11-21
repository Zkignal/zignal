import Foundation
import Observation
import SwiftUI

/// App-wide state: first-run setup, the lock screen, and the unlocked profile.
///
/// The unlocked UI never says whether the real or the decoy profile is open.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case starting
        case setup
        case locked
        case unlocked(ProfileSession)
    }

    private(set) var phase: Phase = .starting
    private(set) var busy = false
    /// Set after too many wrong PINs: no PIN is checked before this time on `BootClock`, which
    /// changing the date or time doesn't move.
    private(set) var lockedUntil: UInt64?
    var errorText: String?

    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private var inBackground = false
    /// The least time between an accepted PIN and its profile showing. Opening takes longer the
    /// more a profile holds, and a panic unlock saves once more first; with a floor above both,
    /// timing an unlock doesn't show which profile opened or whether a wipe ran.
    static let minimumOpen: Duration = .milliseconds(750)
    private static let installedKey = "installed"

    init(store: ProfileStore = .standard()) {
        self.store = store
    }

    // MARK: - Launch

    func start() {
        guard case .starting = phase else { return }
        do {
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: Self.installedKey) {
                // First launch of this install. iOS keeps Keychain items after an app is
                // deleted, so clear anything a previous install left behind.
                for item in Keychain.Item.allCases { try Keychain.delete(item) }
                try store.removeAll()
                defaults.set(true, forKey: Self.installedKey)
            }
            try store.prepare()
            // Older versions let the Zcash SDK keep one setting per wallet in the app's
            // preferences, which go into device backups. It now lives in the wallet's folder.
            WalletFiles.removeAllSDKDefaults()
            // Reading the vault also moves an older install's Keychain items under the
            // Secure Enclave seal (DeviceSecrets).
            phase = try DeviceSecrets.app.read(.vault) == nil ? .setup : .locked
        } catch {
            // Usually the Keychain is unavailable because the phone is still locked.
            // unlock() reads the vault again.
            phase = .locked
            errorText = Self.describe(error)
        }
    }

    // MARK: - Setup

    /// Creates the real and decoy profiles. With `restore`, the real profile, the decoy or both
    /// come from recovery phrases (see `RestoredProfile`) and a profile without one is new; chat
    /// history is never part of a phrase, so it starts empty.
    func createProfiles(realPin: String, duressPin: String, panicPin: String,
                        restore: RestoredProfile? = nil) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let restoredSecret = restore?.realSecret
            let restoredDecoySecret = restore?.decoySecret
            // A new wallet's date is today; a restored one keeps what was entered (see `WalletStart`).
            let walletCreated = restore == nil ? Date() : restore?.created
            let startHeight = restore?.height
            let restoredReal = restoredSecret != nil
            let restoredDecoy = restoredDecoySecret != nil
            let store = self.store
            // Argon2id (once per PIN) and writing both profiles run off the main thread.
            let (realKeys, seed) = try await Task.detached(priority: .userInitiated) {
                let created = try VaultOps.create(realPin: realPin, duressPin: duressPin,
                                                  panicPin: panicPin,
                                                  restoredSecret: restoredSecret,
                                                  restoredDecoySecret: restoredDecoySecret)
                let realKeys = try ProfileKeyset(secret: created.realSecret)
                let decoyKeys = try ProfileKeyset(secret: created.decoySecret)
                // Fresh device key and Secure Enclave key, and both profiles written together
                // so they look alike from day one. Anything left from an earlier, unfinished
                // setup is removed.
                try DeviceSecrets.app.removeAll()
                try store.prepare()
                try store.reset(with: [
                    (ProfileSession.emptyData(keys: realKeys,
                                              walletCreated: restoredReal ? walletCreated : Date(),
                                              restored: restoredReal,
                                              startHeight: restoredReal ? startHeight : nil), realKeys),
                    (ProfileSession.emptyData(keys: decoyKeys,
                                              walletCreated: restoredDecoy ? walletCreated : Date(),
                                              restored: restoredDecoy,
                                              startHeight: restoredDecoy ? startHeight : nil), decoyKeys),
                ])
                // The vault is stored last: if anything above fails, setup simply runs again.
                try DeviceSecrets.app.write(created.vault, to: .vault)
                return (realKeys, try walletSeed(profileSecret: created.realSecret))
            }.value
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            AttemptLimiter.reset()
            lockedUntil = nil
            let session = try await ProfileSession.open(keys: realKeys, store: store)
            show(session, walletSeed: seed)
        } catch {
            errorText = Self.describe(error)
        }
    }

    // MARK: - Lock and unlock

    func unlock(pin: String) async {
        guard !busy else { return }
        errorText = nil
        busy = true
        defer { busy = false }
        do {
            // The unlock screen shows a countdown while this is set.
            guard try updateLockout() == nil else { return }
            guard let vault = try DeviceSecrets.app.read(.vault) else {
                phase = .setup
                return
            }
            // Counted before the check. A PIN that opens a profile takes back only its own count:
            // unlocking, with any of the three PINs, never earns tries back.
            let before = try AttemptLimiter.recordAttempt()
            let result = try await Task.detached(priority: .userInitiated) {
                try VaultOps.unlock(vault: vault, pin: pin)
            }.value
            let wiped = result.vault != vault
            guard let secret = result.secret else {
                errorText = "Wrong PIN."
                try updateLockout()
                return
            }
            let accepted = ContinuousClock.now
            if wiped {
                try DeviceSecrets.app.write(result.vault, to: .vault) // a silent wipe ran
            } else {
                // Every successful unlock stores the vault again, sealed afresh, so its bytes and
                // the Keychain's change date move on every unlock and don't mark the moment a
                // panic PIN was used. A failure here changes nothing and doesn't block the unlock.
                try? DeviceSecrets.app.write(result.vault, to: .vault)
            }
            AttemptLimiter.takeBack(to: before)
            lockedUntil = nil
            let keys = try ProfileKeyset(secret: secret)
            if wiped {
                // Remembered inside this profile's own sealed data until the wipe is confirmed
                // finished, so an interrupted wipe (the app killed, the phone off) is finished the
                // next time this profile opens, with either of its PINs.
                try? store.setWipePending(true, for: keys)
            }
            let pending = wiped || (try? store.wipePending(for: keys)) == true
            let seed = try await Task.detached(priority: .userInitiated) {
                try walletSeed(profileSecret: secret)
            }.value
            let session = try await ProfileSession.open(keys: keys, store: store)
            // Every unlock takes at least `minimumOpen` from the accepted PIN to this point.
            let worked = accepted.duration(to: ContinuousClock.now)
            if worked < Self.minimumOpen { try? await Task.sleep(for: Self.minimumOpen - worked) }
            #if DEBUG
            print("Zignal debug: unlock worked \(worked) from the accepted PIN to an open profile; shown after \(Self.minimumOpen)")
            #endif
            show(session, walletSeed: seed)
            // After the profile is on screen, so a panic unlock (or one that finishes an
            // interrupted wipe) doesn't wait for the clean-up. (It still saves the profile files
            // once more than other unlocks, above: setWipePending.)
            if pending {
                finishWipe(alias: keys.walletAlias, file: store.fileURL(for: keys), session: session)
            }
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// Deletes everything of the wiped profile, in the background, while the open profile is
    /// already on screen: its profile file (replaced by filler), its wallet files and the SDK's
    /// per-wallet settings. A wallet stopped on an earlier lock may still be finishing its last
    /// step and could write its files again, so it waits for that first. Holds only the open
    /// profile's wallet alias and file name, and the session weakly.
    ///
    /// The wipe counts as finished only after two unlocks in a row find nothing left
    /// (`ProfileSession.recordWipePass`); until then each unlock of this profile runs it again.
    private func finishWipe(alias: String, file: URL, session: ProfileSession) {
        let store = store
        Task { [weak session] in
            let settled = await WalletShutdown.waitForAll()
            Self.removeEverythingBut(alias)
            let filesRemoved = (try? store.removeOthers(keepingFile: file)) != nil
            let clean = settled && filesRemoved && WalletFiles.holdsOnly(alias)
            session?.recordWipePass(clean: clean)
            if !settled {
                // Still running after the wait: delete again once it has stopped.
                await WalletShutdown.waitForAll(timeout: .seconds(300))
                Self.removeEverythingBut(alias)
            }
        }
    }

    /// Deletes the wallet files and the SDK's wallet settings of every profile but this one.
    private static func removeEverythingBut(_ keepAlias: String) {
        WalletFiles.removeWallets(except: keepAlias)
        WalletFiles.removeSDKDefaults(except: keepAlias)
    }

    /// Shows any wrong-PIN wait as soon as a PIN screen appears, before anything is typed.
    /// If the counter can't be read here, the PIN check reads it again and fails closed.
    func refreshLockout() {
        _ = try? updateLockout()
    }

    /// Seconds left before the next PIN can be checked; 0 when there's no wait.
    func remainingWait() -> TimeInterval {
        guard let lockedUntil else { return 0 }
        let now = BootClock.now()
        return lockedUntil > now ? Double(lockedUntil - now) / 1_000_000_000 : 0
    }

    /// Reads the wrong-PIN counter and sets `lockedUntil`. Throws if the Keychain can't be
    /// read, so a PIN check fails closed.
    @discardableResult
    private func updateLockout() throws -> UInt64? {
        let now = BootClock.now()
        let wait = AttemptLimiter.waitTime(try AttemptLimiter.load(now: now), now: now)
        lockedUntil = wait > 0 ? now + UInt64((wait * 1_000_000_000).rounded(.up)) : nil
        return lockedUntil
    }

    /// Shows an opened profile and starts its wallet, unless the app went to the background
    /// while it was opening.
    private func show(_ session: ProfileSession, walletSeed: Data) {
        // Whatever Zignal copied before this unlock (a message, an invite, an address) goes, so
        // it can't be pasted into the profile now opening: the other one may be the decoy.
        Clipboard.clearOurCopy()
        if inBackground {
            session.close()
            phase = .locked
        } else {
            phase = .unlocked(session)
            Task { await session.startWallet(seed: walletSeed) }
        }
    }

    // MARK: - Recovery phrase

    enum PhraseReveal {
        case phrase(String)
        case wrongPin
        /// Too many wrong PINs; the screen shows the countdown from `lockedUntil`.
        case waiting
        case refused(String)
    }

    /// Shows the open profile's recovery phrase after checking its PIN again. Attempts count
    /// toward the same wrong-PIN limit as unlocking. A PIN for the other profile is treated as
    /// wrong, and so is the panic PIN (`PhraseCheck`). The vault returned by the check is never
    /// saved, so entering the panic PIN here can't trigger the silent wipe.
    func revealRecoveryPhrase(pin: String, for session: ProfileSession) async -> PhraseReveal {
        do {
            guard try updateLockout() == nil else { return .waiting }
            guard let vault = try DeviceSecrets.app.read(.vault) else { return .wrongPin }
            let before = try AttemptLimiter.recordAttempt()
            let result = try await Task.detached(priority: .userInitiated) {
                try VaultOps.unlock(vault: vault, pin: pin)
            }.value
            guard let secret = PhraseCheck.secret(result, stored: vault),
                  session.belongs(to: try ProfileKeyset(secret: secret)) else {
                try updateLockout()
                return .wrongPin
            }
            AttemptLimiter.takeBack(to: before)
            lockedUntil = nil
            return .phrase(try recoveryPhrase(profileSecret: secret))
        } catch {
            return .refused(Self.describe(error))
        }
    }

    /// Locks the open profile. The Lock button also removes Zignal's copy from the pasteboard;
    /// going to the background keeps it (until it expires after 60 seconds, or the next unlock
    /// removes it), so an invite or address copied here can still be pasted into another app.
    func lock(clearingClipboard: Bool = true) {
        if clearingClipboard { Clipboard.clearOurCopy() }
        guard case .unlocked(let session) = phase else { return }
        session.close()
        phase = .locked
    }

    /// Locks as soon as the app goes to the background.
    func scenePhaseChanged(_ newPhase: ScenePhase) {
        #if DEBUG
        Clipboard.debugLog("scene phase \(newPhase)")
        #endif
        inBackground = newPhase == .background
        if inBackground { lock(clearingClipboard: false) }
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        if let error = error as? ZignalError, let text = error.errorDescription { return text }
        #if DEBUG
        return "Something went wrong (\(error))."
        #else
        return "Something went wrong. Please try again."
        #endif
    }

    /// "Too many wrong PINs. Try again in 0:27." for a live countdown.
    nonisolated static func waitMessage(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return "Too many wrong PINs. Try again in \(s / 60):\(String(format: "%02d", s % 60))."
    }

    /// Shown under the countdown: what makes the wrong-PIN count start over. Unlocking doesn't.
    nonisolated static var restNote: String {
        "After \(AttemptLimiter.quietPeriod / 3_600_000_000_000) hours with no wrong PIN, the count starts over."
    }
}
