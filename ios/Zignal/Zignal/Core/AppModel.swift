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

    func createProfiles(realPin: String, duressPin: String, wipeRealOnDuress: Bool) async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let created = try await Task.detached(priority: .userInitiated) {
                try VaultOps.create(realPin: realPin, duressPin: duressPin,
                                    wipeRealOnDuress: wipeRealOnDuress)
            }.value
            let realKeys = try ProfileKeyset(secret: created.realSecret)
            let decoyKeys = try ProfileKeyset(secret: created.decoySecret)
            // Fresh device key, and both profiles written together so they look alike from
            // day one. Anything left from an earlier, unfinished setup is removed.
            try Keychain.delete(.fileKey)
            try store.prepare()
            try store.reset(with: [
                (ProfileSession.emptyData(keys: realKeys), realKeys),
                (ProfileSession.emptyData(keys: decoyKeys), decoyKeys),
            ])
            // The vault is stored last: if anything above fails, setup simply runs again.
            try Keychain.write(created.vault, to: .vault)
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            AttemptLimiter.reset()
            let session = try ProfileSession.open(keys: realKeys, store: store)
            phase = inBackground ? .locked : .unlocked(session)
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
            let wait = AttemptLimiter.waitTime(try AttemptLimiter.load())
            guard wait <= 0 else {
                errorText = "Too many wrong PINs. Try again in \(Self.format(wait))."
                return
            }
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
                return
            }
            AttemptLimiter.reset()
            let session = try ProfileSession.open(keys: ProfileKeyset(secret: secret), store: store)
            if !inBackground { phase = .unlocked(session) }
        } catch {
            errorText = Self.describe(error)
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

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s < 60 ? "\(s) seconds" : "\((s + 59) / 60) minutes"
    }
}
