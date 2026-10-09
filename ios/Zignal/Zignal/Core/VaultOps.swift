import Foundation

/// Duress-vault operations (zkw-core). Each call runs Argon2id with 64 MiB of memory,
/// which takes around a second, so always call these off the main thread.
enum VaultOps {
    struct Created: Sendable {
        let vault: Data
        let realSecret: Data
        let decoySecret: Data
    }

    struct Unlocked: Sendable {
        /// The opened profile's secret, or nil for a wrong PIN.
        let secret: Data?
        /// Vault bytes after unlocking. Differs from the input only when a silent wipe ran.
        let vault: Data
    }

    /// Creates two independent profiles. Each secret is 32 bytes of fresh entropy, the same
    /// size as a 24-word recovery phrase, so the wallet can be built on it later unchanged.
    static func create(realPin: String, duressPin: String, wipeRealOnDuress: Bool) throws -> Created {
        let real = try secureRandom(32)
        let decoy = try secureRandom(32)
        let vault = try vaultCreate(realPin: realPin, realSecret: real, duressPin: duressPin,
                                    decoySecret: decoy, wipeRealOnDuress: wipeRealOnDuress)
        return Created(vault: vault, realSecret: real, decoySecret: decoy)
    }

    static func unlock(vault: Data, pin: String) throws -> Unlocked {
        let result = try vaultUnlock(vault: vault, pin: pin)
        return Unlocked(secret: result.secret, vault: result.vault)
    }
}

/// Rules for unlock and duress PINs.
enum PinPolicy {
    static let minLength = 6
    static let maxLength = 16

    enum Problem: Equatable {
        case tooShort
        case notDigits
        case tooSimple
    }

    static func problem(_ pin: String) -> Problem? {
        guard pin.allSatisfy({ "0123456789".contains($0) }) else { return .notDigits }
        guard pin.count >= minLength else { return .tooShort }
        return isTooSimple(pin) ? .tooSimple : nil
    }

    static func message(_ problem: Problem) -> String {
        switch problem {
        case .tooShort: "Use at least \(minLength) digits."
        case .notDigits: "Use digits only."
        case .tooSimple: "Too easy to guess. Avoid repeats and sequences."
        }
    }

    /// Rejects one repeated digit (000000), straight runs (123456, 987654, 890123)
    /// and short repeating patterns (121212, 123123).
    private static func isTooSimple(_ pin: String) -> Bool {
        let digits = pin.compactMap(\.wholeNumberValue)
        let steps = Set(zip(digits, digits.dropFirst()).map { ($1 - $0 + 10) % 10 })
        if steps.count == 1, let step = steps.first, [0, 1, 9].contains(step) { return true }
        for period in 2...3 where digits.count > period {
            if digits.indices.allSatisfy({ digits[$0] == digits[$0 % period] }) { return true }
        }
        return false
    }
}

/// Slows down PIN guessing inside the app: 5 free attempts, then a wait that doubles from
/// 30 seconds up to 1 hour. Someone who copies the Keychain off the device isn't slowed by
/// this; Argon2id is the defence there. Known gap: moving the phone's clock forward shortens
/// the wait.
enum AttemptLimiter {
    struct State: Codable {
        var failures = 0
        var last = Date.distantPast
    }

    static let freeAttempts = 5

    static func waitTime(_ state: State, now: Date = Date()) -> TimeInterval {
        guard state.failures >= freeAttempts else { return 0 }
        let delay = min(30 * pow(2, Double(state.failures - freeAttempts)), 3600)
        // Capped at `delay` in case the clock was moved backwards.
        return min(max(0, state.last.addingTimeInterval(delay).timeIntervalSince(now)), delay)
    }

    /// Throws if the Keychain can't be read, so unlocking fails closed.
    static func load() throws -> State {
        guard let data = try Keychain.read(.attempts) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    /// Counts an attempt before the PIN is checked, so force-quitting the app during the
    /// check can't skip it. A successful unlock resets the count.
    static func recordAttempt() throws {
        var state = try load()
        state.failures += 1
        state.last = Date()
        try Keychain.write(JSONEncoder().encode(state), to: .attempts)
    }

    static func reset() {
        try? Keychain.delete(.attempts)
    }
}
