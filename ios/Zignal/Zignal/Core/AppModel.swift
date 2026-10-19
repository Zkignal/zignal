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
    /// Set after too many wrong PINs: no PIN is checked before this time.
    private(set) var lockedUntil: Date?
    var errorText: String?

    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private var inBackground = false
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
            phase = try Keychain.read(.vault) == nil ? .setup : .locked
        } catch {
            // Usually the Keychain is unavailable because the phone is still locked.
            // unlock() reads the vault again.
            phase = .locked
            errorText = Self.describe(error)
        }
    }

    // MARK: - Setup

    /// Creates the real and decoy profiles. With `restore`, the real profile comes from a
    /// recovery phrase; chat history is never part of a phrase, so it starts empty.
    func createProfiles(realPin: String, duressPin: String, wipeRealOnDuress: Bool,
                        restore: RestoredProfile? = nil) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let restoredSecret = restore?.secret
            let walletCreated = restore?.created ?? Date()
            let store = self.store
            // Argon2id (once per PIN) and writing both profiles run off the main thread.
            let realKeys = try await Task.detached(priority: .userInitiated) {
                let created = try VaultOps.create(realPin: realPin, duressPin: duressPin,
                                                  wipeRealOnDuress: wipeRealOnDuress,
                                                  restoredSecret: restoredSecret)
                let realKeys = try ProfileKeyset(secret: created.realSecret)
                let decoyKeys = try ProfileKeyset(secret: created.decoySecret)
                // Fresh device key, and both profiles written together so they look alike
                // from day one. Anything left from an earlier, unfinished setup is removed.
                try Keychain.delete(.fileKey)
                try store.prepare()
                try store.reset(with: [
                    (ProfileSession.emptyData(keys: realKeys, walletCreated: walletCreated), realKeys),
                    (ProfileSession.emptyData(keys: decoyKeys), decoyKeys),
                ])
                // The vault is stored last: if anything above fails, setup simply runs again.
                try Keychain.write(created.vault, to: .vault)
                return realKeys
            }.value
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            AttemptLimiter.reset()
            lockedUntil = nil
            let session = try await ProfileSession.open(keys: realKeys, store: store)
            show(session)
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
            guard let vault = try Keychain.read(.vault) else {
                phase = .setup
                return
            }
            // Counted before the check; reset only after a successful unlock.
            try AttemptLimiter.recordAttempt()
            let result = try await Task.detached(priority: .userInitiated) {
                try VaultOps.unlock(vault: vault, pin: pin)
            }.value
            if result.vault != vault {
                try Keychain.write(result.vault, to: .vault) // a silent wipe ran
            }
            guard let secret = result.secret else {
                errorText = "Wrong PIN."
                try updateLockout()
                return
            }
            AttemptLimiter.reset()
            lockedUntil = nil
            let keys = try ProfileKeyset(secret: secret)
            show(try await ProfileSession.open(keys: keys, store: store))
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// Shows any wrong-PIN wait as soon as a PIN screen appears, before anything is typed.
    /// If the counter can't be read here, the PIN check reads it again and fails closed.
    func refreshLockout() {
        _ = try? updateLockout()
    }

    /// Seconds left before the next PIN can be checked; 0 when there's no wait.
    func remainingWait(at date: Date = Date()) -> TimeInterval {
        guard let lockedUntil else { return 0 }
        return max(0, lockedUntil.timeIntervalSince(date))
    }

    /// Reads the wrong-PIN counter and sets `lockedUntil`. Throws if the Keychain can't be
    /// read, so a PIN check fails closed.
    @discardableResult
    private func updateLockout() throws -> Date? {
        let wait = AttemptLimiter.waitTime(try AttemptLimiter.load())
        lockedUntil = wait > 0 ? Date().addingTimeInterval(wait) : nil
        return lockedUntil
    }

    /// Shows an opened profile, unless the app went to the background while it was opening.
    private func show(_ session: ProfileSession) {
        if inBackground {
            session.close()
            phase = .locked
        } else {
            phase = .unlocked(session)
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
    /// wrong, and the vault returned by the check is never saved, so entering the duress PIN
    /// here can't trigger the silent wipe.
    func revealRecoveryPhrase(pin: String, for session: ProfileSession) async -> PhraseReveal {
        do {
            guard try updateLockout() == nil else { return .waiting }
            guard let vault = try Keychain.read(.vault) else { return .wrongPin }
            try AttemptLimiter.recordAttempt()
            let result = try await Task.detached(priority: .userInitiated) {
                try VaultOps.unlock(vault: vault, pin: pin)
            }.value
            guard let secret = result.secret, session.belongs(to: try ProfileKeyset(secret: secret)) else {
                try updateLockout()
                return .wrongPin
            }
            AttemptLimiter.reset()
            lockedUntil = nil
            return .phrase(try recoveryPhrase(profileSecret: secret))
        } catch {
            return .refused(Self.describe(error))
        }
    }

    func lock() {
        guard case .unlocked(let session) = phase else { return }
        session.close()
        phase = .locked
    }

    /// Locks as soon as the app goes to the background.
    func scenePhaseChanged(_ newPhase: ScenePhase) {
        inBackground = newPhase == .background
        if inBackground { lock() }
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
}
