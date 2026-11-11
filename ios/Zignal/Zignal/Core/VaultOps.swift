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

    /// Creates two independent profiles behind three PINs: the unlock PIN opens the real
    /// profile, the duress PIN opens the decoy, and the panic PIN opens the decoy after silently
    /// wiping the real profile. Each secret is 32 bytes of entropy, which is exactly one 24-word
    /// recovery phrase. `restoredSecret` (from a recovery phrase) becomes the real profile;
    /// otherwise both secrets are fresh. The decoy is always fresh.
    static func create(realPin: String, duressPin: String, panicPin: String,
                       restoredSecret: Data? = nil) throws -> Created {
        if let restoredSecret, restoredSecret.count != 32 { throw ZignalError.invalidRecoveryPhrase }
        let real = try restoredSecret ?? secureRandom(32)
        let decoy = try secureRandom(32)
        let vault = try vaultCreate(realPin: realPin, realSecret: real, duressPin: duressPin,
                                    decoySecret: decoy, panicPin: panicPin)
        return Created(vault: vault, realSecret: real, decoySecret: decoy)
    }

    static func unlock(vault: Data, pin: String) throws -> Unlocked {
        let result = try vaultUnlock(vault: vault, pin: pin)
        return Unlocked(secret: result.secret, vault: result.vault)
    }
}

/// Rules for the unlock, duress and panic PINs.
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

/// Nanoseconds on the clock behind Swift's `ContinuousClock` (`CLOCK_MONOTONIC_RAW`). It keeps
/// counting while the phone sleeps and can't be set: changing the date or time doesn't move it.
/// Apple documents its starting point only as arbitrary, so a value below a saved one is
/// treated as a restart (`AttemptLimiter.normalized`).
enum BootClock {
    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

/// Slows down PIN guessing inside the app: 5 free attempts, then a wait that doubles from
/// 30 seconds up to 1 hour. The wait is measured on `BootClock`, so changing the date or time
/// doesn't shorten it, and a restart can start it over but never shortens it. A copy of the
/// Keychain taken off the phone can't be used to guess PINs elsewhere: the vault is sealed by
/// this phone's Secure Enclave (`DeviceSecrets`).
enum AttemptLimiter {
    struct State: Codable {
        var failures = 0
        /// `BootClock` at the last attempt. Nil in state saved by older versions, which saved
        /// a date instead.
        var uptime: UInt64?
    }

    static let freeAttempts = 5
    private static let nanosecondsPerSecond = 1_000_000_000.0

    static func waitTime(_ state: State, now: UInt64) -> TimeInterval {
        guard state.failures >= freeAttempts else { return 0 }
        let delay = min(30 * pow(2, Double(state.failures - freeAttempts)), 3600)
        // No stamp, or one from before a restart: the whole wait. Never less than the real time.
        guard let last = state.uptime, now >= last else { return delay }
        return max(0, delay - Double(now - last) / nanosecondsPerSecond)
    }

    /// A stamp from before a restart (the clock started again below it) or from an older
    /// version (no stamp) starts the wait over from now.
    static func normalized(_ state: State, now: UInt64) -> State {
        guard state.failures > 0, state.uptime.map({ now < $0 }) ?? true else { return state }
        var restarted = state
        restarted.uptime = now
        return restarted
    }

    /// Throws if the Keychain can't be read, so unlocking fails closed.
    static func load(now: UInt64 = BootClock.now()) throws -> State {
        guard let data = try Keychain.read(.attempts) else { return State() }
        let saved = (try? JSONDecoder().decode(State.self, from: data)) ?? State()
        let state = normalized(saved, now: now)
        if state.uptime != saved.uptime { try save(state) }
        return state
    }

    /// Counts an attempt before the PIN is checked, so force-quitting the app during the
    /// check can't skip it. A successful unlock resets the count.
    static func recordAttempt(now: UInt64 = BootClock.now()) throws {
        var state = try load(now: now)
        state.failures += 1
        state.uptime = now
        try save(state)
    }

    static func reset() {
        try? Keychain.delete(.attempts)
    }

    private static func save(_ state: State) throws {
        try Keychain.write(JSONEncoder().encode(state), to: .attempts)
    }
}
