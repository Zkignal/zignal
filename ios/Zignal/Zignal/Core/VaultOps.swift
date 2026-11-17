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

/// Which PIN may show the open profile's recovery phrase (`AppModel.revealRecoveryPhrase`).
enum PhraseCheck {
    /// The opened profile's secret, or nil for a wrong PIN and for a PIN whose check would wipe a
    /// profile. The panic PIN opens the decoy too: if it showed the decoy's phrase, someone in
    /// the decoy could find the panic PIN there without setting it off, and then avoid it.
    static func secret(_ result: VaultOps.Unlocked, stored: Data) -> Data? {
        guard result.vault == stored else { return nil }
        return result.secret
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

/// Slows down PIN guessing inside the app. 5 wrong PINs are free; past them, each try waits,
/// doubling from 30 seconds up to 1 hour. After 2 hours with no wrong PIN, every free try is
/// back. Every PIN that's checked is counted first; a PIN that opens a profile then takes back
/// only its own count, so unlocking, with any of the three PINs, never clears earlier wrong PINs
/// (before, it reset the count, and someone who knew the duress PIN was never slowed down).
/// Only quiet time does: someone guessing gets 5 tries, then has to stop for 2 hours.
///
/// Time is measured on `BootClock`, so changing the date or time doesn't move it, and a
/// restart starts the wait and the 2 hours over but never shortens either. A copy of the
/// Keychain taken off the phone can't be used to guess PINs elsewhere: the vault is sealed by
/// this phone's Secure Enclave (`DeviceSecrets`).
enum AttemptLimiter {
    struct State: Codable, Equatable {
        /// Wrong PINs that still count: against the free ones, then toward the wait.
        var failures = 0
        /// `BootClock` at the last wrong PIN (a PIN that opened a profile takes its own stamp
        /// back with its count). Nil in state saved by older versions, which saved a date instead.
        var uptime: UInt64?
    }

    static let freeAttempts = 5
    /// After this long on `BootClock` with no wrong PIN, every free try is back (2 hours).
    static let quietPeriod: UInt64 = 2 * 3600 * 1_000_000_000
    private static let nanosecondsPerSecond = 1_000_000_000.0

    static func waitTime(_ state: State, now: UInt64) -> TimeInterval {
        guard state.failures >= freeAttempts else { return 0 }
        let delay = min(30 * pow(2, Double(state.failures - freeAttempts)), 3600)
        // No stamp, or one from before a restart: the whole wait. Never less than the real time.
        guard let last = state.uptime, now >= last else { return delay }
        return max(0, delay - Double(now - last) / nanosecondsPerSecond)
    }

    /// A stamp from before a restart (the clock started again below it) or from an older
    /// version (no stamp) starts the wait, and the 2 hours, over from now: a restart never
    /// gives a try back.
    static func normalized(_ state: State, now: UInt64) -> State {
        guard state.failures > 0 else { return state }
        var result = state
        if state.uptime.map({ now < $0 }) ?? true { result.uptime = now }
        return result
    }

    /// Every free try back once `quietPeriod` has passed since the last wrong PIN.
    static func rested(_ state: State, now: UInt64) -> State {
        guard state.failures > 0, let last = state.uptime, now >= last,
              now - last >= quietPeriod else { return state }
        return State()
    }

    /// The state with one more attempt counted at `now`.
    static func counted(_ state: State, now: UInt64) -> State {
        var result = rested(normalized(state, now: now), now: now)
        result.failures += 1
        result.uptime = now
        return result
    }

    /// What a counter that can't be decoded stands for: no free tries left, and the 2 hours
    /// starting now. Never a fresh start.
    static func unreadable(now: UInt64) -> State {
        State(failures: freeAttempts, uptime: now)
    }

    /// Throws if the Keychain can't be read, so unlocking fails closed.
    static func load(now: UInt64 = BootClock.now()) throws -> State {
        guard let data = try Keychain.read(.attempts) else { return State() }
        let saved = try? JSONDecoder().decode(State.self, from: data)
        let state = rested(normalized(saved ?? unreadable(now: now), now: now), now: now)
        if saved != state { try save(state) }
        return state
    }

    /// Counts an attempt before the PIN is checked, so force-quitting the app during the
    /// check can't skip it. Returns the state from before it, for `takeBack(to:)`.
    static func recordAttempt(now: UInt64 = BootClock.now()) throws -> State {
        let before = try load(now: now)
        try save(counted(before, now: now))
        return before
    }

    /// After a PIN opened a profile, takes back the attempt `recordAttempt` counted for it, and
    /// only that one: unlocking never earns tries back, whichever PIN was used. If this can't be
    /// saved, the attempt stays counted, which is the safe side.
    static func takeBack(to before: State) {
        if before.failures == 0 {
            try? Keychain.delete(.attempts)
        } else {
            try? save(before)
        }
    }

    /// Clears the count. Only setup uses it: a new vault starts with every free try.
    static func reset() {
        try? Keychain.delete(.attempts)
    }

    private static func save(_ state: State) throws {
        try Keychain.write(JSONEncoder().encode(state), to: .attempts)
    }
}
