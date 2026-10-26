import CryptoKit
import Foundation
import Testing
@testable import Zignal

/// A profile store in a fresh temporary folder with its own device key, so tests never touch
/// the app's real data or the Keychain.
private func makeTempStore() throws -> ProfileStore {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "zignal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ProfileStore(directory: dir, deviceKeySource: .fixed(SymmetricKey(size: .bits256)))
    try store.prepare()
    return store
}

private func fileNames(_ store: ProfileStore) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
}

struct PinPolicyTests {
    @Test func rejectsShortAndNonDigitPins() {
        #expect(PinPolicy.problem("") == .tooShort)
        #expect(PinPolicy.problem("58391") == .tooShort)
        #expect(PinPolicy.problem("58a914") == .notDigits)
    }

    @Test(arguments: ["000000", "123456", "987654", "890123", "121212", "123123"])
    func rejectsGuessablePatterns(pin: String) {
        #expect(PinPolicy.problem(pin) == .tooSimple)
    }

    @Test func acceptsOrdinaryPins() {
        #expect(PinPolicy.problem("583914") == nil)
        #expect(PinPolicy.problem("2604719") == nil)
    }
}

struct AttemptLimiterTests {
    @Test func freeAttemptsThenDoublingWait() {
        let now = Date()
        func wait(_ failures: Int, after seconds: TimeInterval = 0) -> TimeInterval {
            AttemptLimiter.waitTime(.init(failures: failures, last: now), now: now + seconds)
        }
        #expect(wait(4) == 0)
        #expect(abs(wait(5) - 30) < 0.01)
        #expect(abs(wait(6) - 60) < 0.01)
        #expect(abs(wait(40) - 3600) < 0.01)
        #expect(wait(5, after: 31) == 0)
    }

    @Test func waitMessageCountsDownInMinutesAndSeconds() {
        #expect(AppModel.waitMessage(27) == "Too many wrong PINs. Try again in 0:27.")
        #expect(AppModel.waitMessage(90.2) == "Too many wrong PINs. Try again in 1:31.")
        #expect(AppModel.waitMessage(3600) == "Too many wrong PINs. Try again in 60:00.")
    }
}

struct ProfileStoreTests {
    @Test func garbageBlockIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        #expect(throws: ZignalError.self) { try ProfileStore.openBlock(Data(count: 8), key: key) }
        let random = try secureRandom(ProfileStore.minBucket)
        #expect(throws: (any Error).self) { try ProfileStore.openBlock(random, key: key) }
    }

    @Test func profilesAreSeparateAndLookAlike() throws {
        let store = try makeTempStore()
        let a = try ProfileKeyset(secret: secureRandom(32))
        let b = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileData(inbox: Data([1, 2, 3])), a),
                               (ProfileData(inbox: Data([4, 5])), b)])

        #expect(try store.load(a)?.inbox == Data([1, 2, 3]))
        #expect(try store.load(b)?.inbox == Data([4, 5]))
        #expect(store.fileURL(for: a) != store.fileURL(for: b))
        #expect(try fileNames(store).count == 2)

        // Saving A re-seals B as well: B's bytes change, its content doesn't.
        let bBefore = try Data(contentsOf: store.fileURL(for: b))
        try store.save(ProfileData(inbox: Data(count: 3 * ProfileStore.minBucket)), a)
        let bAfter = try Data(contentsOf: store.fileURL(for: b))
        #expect(bBefore != bAfter)
        #expect(try store.load(b)?.inbox == Data([4, 5]))

        // Both files grew to the same size bucket and share timestamps.
        let fm = FileManager.default
        let attributes = try fileNames(store).map {
            try fm.attributesOfItem(atPath: store.directory.appending(path: $0).path)
        }
        let sizes = Set(attributes.map { $0[.size] as? Int })
        #expect(sizes.count == 1)
        let size = try #require(attributes.first?[.size] as? Int)
        #expect(size > 3 * ProfileStore.minBucket)
        #expect(Set(attributes.map { $0[.modificationDate] as? Date }).count == 1)
    }

    @Test func aLoneProfileGetsAFillerFile() throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.save(ProfileData(inbox: Data([7])), keys)
        #expect(try fileNames(store).count == ProfileStore.minimumFiles)
        try store.save(ProfileData(inbox: Data([8])), keys)
        #expect(try fileNames(store).count == ProfileStore.minimumFiles)
        #expect(try store.load(keys)?.inbox == Data([8]))
    }

    @Test func tamperedFileIsRejected() throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.save(ProfileData(inbox: Data([9])), keys)
        let url = store.fileURL(for: keys)
        var bytes = try Data(contentsOf: url)
        bytes[100] ^= 0x01
        try bytes.write(to: url)
        #expect(throws: ZignalError.self) { try store.load(keys) }
    }

    @Test func wrongDeviceKeyCantOpenFiles() throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.save(ProfileData(inbox: Data([1])), keys)
        let otherDevice = ProfileStore(directory: store.directory,
                                       deviceKeySource: .fixed(SymmetricKey(size: .bits256)))
        #expect(throws: ZignalError.self) { try otherDevice.load(keys) }
    }

    @Test func oldProfileFilesStillDecode() throws {
        let old = Data(#"{"version":1,"inbox":"AQ==","contacts":[],"messages":[]}"#.utf8)
        let data = try JSONDecoder().decode(ProfileData.self, from: old)
        #expect(data.inbox == Data([1]))
        #expect(data.walletCreated == nil)
        #expect(data.recoveryPhraseShown == nil)
    }

    @Test func missingFileLoadsAsNil() throws {
        let store = try makeTempStore()
        #expect(try store.load(ProfileKeyset(secret: secureRandom(32))) == nil)
    }
}

struct RecoveryPhraseTests {
    @Test func phraseRestoresTheSameProfile() throws {
        let secret = try secureRandom(32)
        let phrase = try recoveryPhrase(profileSecret: secret)
        #expect(phrase.split(separator: " ").count == 24)
        let restored = try profileSecretFromPhrase(phrase: "  " + phrase.uppercased() + "\n")
        #expect(restored == secret)
        let original = try ProfileKeyset(secret: secret)
        let again = try ProfileKeyset(secret: restored)
        #expect(original.identitySeed == again.identitySeed)
        #expect(original.stateKey == again.stateKey)
        #expect(try walletSeed(profileSecret: secret).count == 64)
        #expect(try walletSeed(profileSecret: restored) == walletSeed(profileSecret: secret))
    }

    @Test func invalidPhrasesAreRejected() {
        #expect(throws: (any Error).self) { try profileSecretFromPhrase(phrase: "abandon abandon") }
        #expect(throws: (any Error).self) {
            try profileSecretFromPhrase(phrase: String(repeating: "zignal ", count: 24))
        }
    }

    /// Runs Argon2id (64 MiB) four times.
    @Test func vaultKeepsARestoredSecret() throws {
        let secret = try secureRandom(32)
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471",
                                          panicPin: "731946", restoredSecret: secret)
        #expect(created.realSecret == secret)
        #expect(created.decoySecret != secret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "583914").secret == secret)
        #expect(throws: ZignalError.self) {
            try VaultOps.create(realPin: "583914", duressPin: "260471",
                                panicPin: "731946", restoredSecret: Data(count: 16))
        }
    }
}

/// Runs Argon2id (64 MiB) several times, so these take a few seconds.
struct VaultTests {
    @Test func unlockDuressPanicAndWrongPin() throws {
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471", panicPin: "731946")
        #expect(try VaultOps.unlock(vault: created.vault, pin: "583914").secret == created.realSecret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "260471").secret == created.decoySecret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "731946").secret == created.decoySecret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "000000").secret == nil)
        #expect(created.realSecret != created.decoySecret)
        #expect(throws: (any Error).self) {
            try VaultOps.create(realPin: "583914", duressPin: "260471", panicPin: "583914")
        }
    }

    @Test func duressPinNeverErasesAnything() throws {
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471", panicPin: "731946")
        let duress = try VaultOps.unlock(vault: created.vault, pin: "260471")
        #expect(duress.secret == created.decoySecret)
        #expect(duress.vault == created.vault)
    }

    @Test func panicPinSilentlyErasesRealProfile() throws {
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471", panicPin: "731946")
        let panic = try VaultOps.unlock(vault: created.vault, pin: "731946")
        #expect(panic.secret == created.decoySecret)
        #expect(panic.vault != created.vault)
        #expect(panic.vault.count == created.vault.count)
        #expect(try VaultOps.unlock(vault: panic.vault, pin: "583914").secret == nil)
        #expect(try VaultOps.unlock(vault: panic.vault, pin: "260471").secret == created.decoySecret)
        #expect(try VaultOps.unlock(vault: panic.vault, pin: "731946").secret == created.decoySecret)
    }
}

@MainActor
struct ProfileSessionTests {
    @Test func demoChatRoundTripSurvivesRestart() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: keys), keys)])

        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)
        #expect(demo.isDemo)
        #expect(session.messages(with: demo.id).count == 2)

        await session.send("second message", to: demo.id)
        #expect(session.messages(with: demo.id).count == 4)
        #expect(session.messages(with: demo.id).last?.text.contains("second message") == true)
        #expect(session.errorText == nil)

        // Reopen from disk: history is intact and both ratchets carry on.
        let reopened = try await ProfileSession.open(keys: keys, store: store)
        reopened.demoReplyDelay = .zero
        #expect(reopened.messages.count == 4)
        await reopened.send("after restart", to: demo.id)
        #expect(reopened.messages(with: demo.id).count == 6)
        #expect(reopened.errorText == nil)
    }

    @Test func realAndDecoyProfilesDontShareAnything() async throws {
        let store = try makeTempStore()
        let real = try ProfileKeyset(secret: secureRandom(32))
        let decoy = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: real), real),
                               (ProfileSession.emptyData(keys: decoy), decoy)])

        let session = try await ProfileSession.open(keys: real, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        #expect(session.contacts.count == 1)

        let other = try await ProfileSession.open(keys: decoy, store: store)
        #expect(other.contacts.isEmpty)
        #expect(other.messages.isEmpty)
    }

    @Test func walletDateAndBackupFlagPersist() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try store.reset(with: [(ProfileSession.emptyData(keys: keys, walletCreated: created), keys)])

        let session = try await ProfileSession.open(keys: keys, store: store)
        #expect(session.walletCreated == created)
        #expect(!session.recoveryPhraseShown)
        #expect(session.belongs(to: keys))
        #expect(!session.belongs(to: try ProfileKeyset(secret: secureRandom(32))))

        session.markRecoveryPhraseShown()
        let reopened = try await ProfileSession.open(keys: keys, store: store)
        #expect(reopened.recoveryPhraseShown)
        #expect(reopened.walletCreated == created)
    }

    @Test func closedSessionNeverSavesAgain() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)
        let before = try store.load(keys)

        session.close()
        await session.send("after lock", to: demo.id)
        #expect(try store.load(keys) == before)
    }

    @Test func lockDuringDeliveryDropsTheReply() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)

        session.demoReplyDelay = .milliseconds(300)
        let sending = Task { await session.send("x", to: demo.id) }
        try await Task.sleep(for: .milliseconds(100))
        session.close()
        await sending.value
        // Our message was saved before delivery; the reply after the lock was not.
        #expect(try store.load(keys)?.messages.count == 3)
    }

    @Test func oversizedMessageIsRefused() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)
        await session.send(String(repeating: "x", count: ProfileSession.maxTextBytes + 1), to: demo.id)
        #expect(session.errorText != nil)
        #expect(session.messages(with: demo.id).count == 2)
    }

    @Test func longMessageUsesSeveralMemos() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)
        await session.send(String(repeating: "y", count: ProfileSession.maxTextBytes), to: demo.id)
        #expect(session.errorText == nil)
        let sent = try #require(session.messages(with: demo.id).last(where: { $0.outgoing }))
        #expect(sent.memoCount > 1)
        #expect(sent.memoCount <= 15)
    }

    @Test func demoContactWithoutStateIsRemovedOnOpen() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try await ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        session.close()

        // Simulate a crash that lost the demo contact's state.
        var saved = try #require(try store.load(keys))
        saved.demoContact = nil
        try store.save(saved, keys)

        let reopened = try await ProfileSession.open(keys: keys, store: store)
        #expect(reopened.contacts.isEmpty)
        #expect(reopened.messages.isEmpty)
        #expect(try store.load(keys)?.contacts.isEmpty == true)
    }
}

/// Times each step of unlocking with the app's real Argon2id settings. The numbers are
/// printed to the test log (Report navigator, Cmd+9, latest test run, search "TIMING"), so a
/// slow step can be found without adding any logging to the app. Other tests (also running
/// Argon2id) run at the same time, so the numbers are an upper bound. The limits are generous:
/// they catch a step that has become far slower, not small differences between machines.
@MainActor
struct UnlockTimingTests {
    @Test func unlockStepsStayFast() async throws {
        let clock = ContinuousClock()

        var start = clock.now
        let created = try VaultOps.create(realPin: "58391402", duressPin: "26047118",
                                          panicPin: "73194652")
        let createTime = start.duration(to: clock.now)

        start = clock.now
        let opened = try VaultOps.unlock(vault: created.vault, pin: "58391402")
        let unlockTime = start.duration(to: clock.now)
        let secret = try #require(opened.secret)

        // A profile with some history, next to the other profile's file.
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secret)
        let decoy = try ProfileKeyset(secret: created.decoySecret)
        try store.reset(with: [(ProfileSession.emptyData(keys: keys), keys),
                               (ProfileSession.emptyData(keys: decoy), decoy)])
        let first = try await ProfileSession.open(keys: keys, store: store)
        first.demoReplyDelay = .zero
        await first.startDemoChat()
        let demo = try #require(first.contacts.first)
        for i in 1...10 { await first.send("message \(i)", to: demo.id) }
        first.close()

        start = clock.now
        let session = try await ProfileSession.open(keys: keys, store: store)
        let openTime = start.duration(to: clock.now)
        #expect(session.messages.count == 22)

        print("TIMING set up all three PINs (Argon2id x3): \(ms(createTime)) ms")
        print("TIMING check one PIN (Argon2id x1): \(ms(unlockTime)) ms")
        print("TIMING open profile (decrypt, restore, re-seal all files): \(ms(openTime)) ms")
        #expect(unlockTime < .seconds(3), "Checking one PIN took \(ms(unlockTime)) ms")
        #expect(openTime < .seconds(1), "Opening the profile took \(ms(openTime)) ms")
    }

    private func ms(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Wallet support (Block 4)

/// A made-up mainnet unified address of realistic length (an Orchard-only address is 106
/// characters). Only its characters matter here; it is never sent anywhere.
private let sampleAddress = "u1" + String(repeating: "qpzry9x8gf2tvdw0s3jn54khce6mua7l", count: 4).prefix(104)

struct PaymentRequestTests {
    @Test func memosBecomeZeroValuePaymentsInOneRequest() throws {
        let first = Data([0xFF]) + Data(repeating: 0xA5, count: 511)
        let second = Data([0xFF]) + Data(repeating: 0x00, count: 511)
        let uri = PaymentRequest.memos([first, second], to: sampleAddress)
        #expect(uri == "zcash:?address=\(sampleAddress)&amount=0&memo=\(Base64URL.encode(first))"
            + "&address.1=\(sampleAddress)&amount.1=0&memo.1=\(Base64URL.encode(second))")
        #expect(Base64URL.decode(Base64URL.encode(first)) == first)
    }

    @Test func splitPaymentsUseIndexedParameters() {
        #expect(PaymentRequest.payments([20_000, 20_000], to: sampleAddress)
            == "zcash:?address=\(sampleAddress)&amount=0.0002&address.1=\(sampleAddress)&amount.1=0.0002")
    }

    @Test func acceptsOnlyPlainShieldedAddresses() {
        #expect(PaymentRequest.isShieldedAddress(sampleAddress))
        // Anything that could add or change request parameters, or isn't a unified address.
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress + "&amount=5"))
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress + "?memo=x"))
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress + "%26amount%3D5"))
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress + " "))
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress.uppercased()))
        #expect(!PaymentRequest.isShieldedAddress("t1" + sampleAddress.dropFirst(2)))
        #expect(!PaymentRequest.isShieldedAddress("zs1" + sampleAddress.dropFirst(2)))
        #expect(!PaymentRequest.isShieldedAddress("utest1" + sampleAddress.dropFirst(2)))
        #expect(!PaymentRequest.isShieldedAddress("u1qpzry9"))
        #expect(!PaymentRequest.isShieldedAddress(""))
        // "b", "i", "o" and "1" are not bech32 data characters.
        #expect(!PaymentRequest.isShieldedAddress(sampleAddress.dropLast() + "b"))
    }

    @Test func amountsAreWrittenAsPlainDecimals() {
        #expect(PaymentRequest.zec(0) == "0")
        #expect(PaymentRequest.zec(1) == "0.00000001")
        #expect(PaymentRequest.zec(10_000) == "0.0001")
        #expect(PaymentRequest.zec(100_000_000) == "1")
        #expect(PaymentRequest.zec(123_456_789) == "1.23456789")
        #expect(ZecFormat.string(10_000) == "0.0001 ZEC")
        #expect(ZecFormat.string(-5_000) == "-0.00005 ZEC")
    }
}

struct Base64URLTests {
    @Test func roundTripsEveryLength() throws {
        for length in 0...70 {
            let bytes = try secureRandom(length)
            let text = Base64URL.encode(bytes)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == bytes)
        }
    }

    @Test func rejectsPaddingAndOtherCharacters() {
        #expect(Base64URL.decode("QQ==") == nil)
        #expect(Base64URL.decode("QQ.Q") == nil)
        #expect(Base64URL.decode("QQ\u{00E9}") == nil)
        #expect(Base64URL.decode("Q") == nil)
    }
}

struct InviteCodeTests {
    /// The invite layout must match zkw-core's: this reads a real invite from the core.
    @Test func readsTheInviterFromARealInvite() throws {
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let inbox = try ZkwInbox(seed: keys.identitySeed, now: unixNow())
        let invite = try inbox.createInvite(myAddress: Data(sampleAddress.utf8))
        let code = InviteCode.encode(invite)
        #expect(code.hasPrefix("zignal:"))
        #expect(InviteCode.decode(code) == invite)
        #expect(InviteCode.inviterID(invite) == (try inbox.myId()))
        #expect(InviteCode.address(invite) == sampleAddress)
        // Fits one QR code: 2,953 bytes at low error correction, 2,331 at medium.
        #expect(code.utf8.count < 2_331, "Invite code is \(code.utf8.count) characters")
    }

    @Test func toleratesWhitespaceAndCase() throws {
        let invite = Data("ZWI1".utf8) + Data([0, 3]) + Data("u1q".utf8) + (try secureRandom(48))
        let code = InviteCode.encode(invite)
        let body = String(code.dropFirst(InviteCode.prefix.count))
        #expect(InviteCode.decode(" \(code)\n") == invite)
        #expect(InviteCode.decode("ZIGNAL:" + body) == invite)
        #expect(InviteCode.decode(body) == invite)
        let wrapped = body.enumerated().map { $0.offset % 40 == 39 ? "\($0.element)\n" : "\($0.element)" }.joined()
        #expect(InviteCode.decode(wrapped) == invite)
    }

    @Test func rejectsWhatIsntAnInvite() throws {
        #expect(InviteCode.decode("") == nil)
        #expect(InviteCode.decode("zignal:") == nil)
        #expect(InviteCode.decode("zcash:\(sampleAddress)") == nil)
        #expect(InviteCode.decode(InviteCode.encode(Data("ZWI2".utf8) + (try secureRandom(60)))) == nil)
        // An address length that runs past the end leaves no room for the inviter's key.
        let short = Data("ZWI1".utf8) + Data([0x01, 0x00]) + Data(repeating: 0x71, count: 40)
        #expect(InviteCode.inviterID(short) == nil)
        #expect(InviteCode.address(short) == nil)
    }
}

/// Why the app reads each message at its block time: the core finds a message's chat by a
/// tag that changes every day, and accepts only yesterday's, today's and tomorrow's.
struct MessageTimingTests {
    @Test func aMessageIsReadAtTheTimeItWasSent() throws {
        let now = unixNow()
        let alice = try ZkwInbox(seed: ProfileKeyset(secret: secureRandom(32)).identitySeed, now: now)
        let bob = try ZkwInbox(seed: ProfileKeyset(secret: secureRandom(32)).identitySeed, now: now)
        let invite = try bob.createInvite(myAddress: Data("u1bob".utf8))
        let start = try alice.startFromInvite(invite: invite, myAddress: Data("u1alice".utf8), firstText: "hi")
        var started = false
        for memo in start.memos {
            if case .newSession(_, let text)? = try bob.receive(memo: memo, now: now) { started = text == "hi" }
        }
        #expect(started)

        let reply = try bob.sendText(peer: try alice.myId(), text: "reply", now: now)
        let threeDaysLater = now + 3 * 86_400
        for memo in reply.memos {
            #expect(try alice.receive(memo: memo, now: threeDaysLater) == nil)
        }
        var read: String?
        for memo in reply.memos {
            if case .message(_, let text)? = try alice.receive(memo: memo, now: now + 75) { read = text }
        }
        #expect(read == "reply")
    }
}

struct IncomingMemosTests {
    private func output(fromUs: Bool = false, change: Bool = false, shielded: Bool = true,
                        _ memo: WalletOutput.Memo) -> WalletOutput {
        WalletOutput(fromUs: fromUs, isChange: change, isShielded: shielded, memo: memo)
    }

    @Test func keepsOnlyBinaryMemosSentToUs() throws {
        let body = [UInt8]("ZW".utf8) + [2, 1]
        let memos = try #require(IncomingMemos.extract(from: [
            output(.binary(body)),
            output(fromUs: true, .binary([1, 2, 3])),
            output(change: true, .binary([4, 5, 6])),
            output(shielded: false, .binary([7, 8, 9])),
            output(.other),
        ]))
        #expect(memos.count == 1)
        let memo = try #require(memos.first)
        #expect(memo.count == 512)
        #expect(memo.first == 0xFF)
        #expect([UInt8](memo[1...4]) == body)
        #expect(memo.dropFirst(5).allSatisfy { $0 == 0 })
    }

    @Test func waitsForMemosThatArentFetchedYet() {
        #expect(IncomingMemos.extract(from: [output(.binary([1])), output(.notFetched)]) == nil)
        // Our own outputs don't matter, fetched or not.
        #expect(IncomingMemos.extract(from: [output(fromUs: true, .notFetched)]) == [])
    }

    @Test func rejectsOversizedMemos() {
        #expect(IncomingMemos.fullMemo(binary: [UInt8](repeating: 1, count: 511))?.count == 512)
        #expect(IncomingMemos.fullMemo(binary: [UInt8](repeating: 1, count: 512)) == nil)
    }
}

struct WalletSettingsTests {
    @Test func parsesServers() {
        #expect(WalletSettings.Server("zec.rocks") == WalletSettings.Server(host: "zec.rocks", port: 443))
        #expect(WalletSettings.Server(" LWD1.zcash-infra.com:9067 \n") == WalletSettings.Server(host: "lwd1.zcash-infra.com", port: 9067))
        #expect(WalletSettings.Server("127.0.0.1:9067") == WalletSettings.Server(host: "127.0.0.1", port: 9067))
    }

    @Test(arguments: ["", ":443", "host:", "host:0", "host:65536", "a:b:c", "https://zec.rocks",
                      "zec.rocks/path", "zec rocks", "zec.rocks:44 3", "zéc.rocks", "[::1]:443"])
    func rejectsAnythingElse(text: String) {
        #expect(WalletSettings.Server(text) == nil)
    }

    @Test func defaultsHaveTorOffAndKnownServers() {
        #expect(!WalletSettings.standard.torEnabled)
        #expect(WalletSettings.standard.servers.first == WalletSettings.Server(host: "zec.rocks", port: 443))
        #expect(WalletSettings.standard.servers.allSatisfy { WalletSettings.Server($0.label) == $0 })
    }

    @Test func olderProfileFilesHaveNoWalletFields() throws {
        let old = Data(#"{"version":1,"inbox":"AQ==","contacts":[],"messages":[]}"#.utf8)
        let data = try JSONDecoder().decode(ProfileData.self, from: old)
        #expect(data.walletRestored == nil)
        #expect(data.walletSettings == nil)
        #expect(data.processedTransactions == nil)
    }
}

struct WalletWipeTests {
    @Test func aliasIsStableAndDiffersPerProfile() throws {
        let secret = try secureRandom(32)
        let one = try ProfileKeyset(secret: secret)
        let again = try ProfileKeyset(secret: secret)
        let other = try ProfileKeyset(secret: secureRandom(32))
        #expect(one.walletAlias.count == 16)
        #expect(one.walletAlias == again.walletAlias)
        #expect(one.walletAlias != other.walletAlias)
    }

    /// After a silent wipe, the wiped profile's file is gone, replaced by filler of the same
    /// size, and the open profile is untouched.
    @Test func wipeLeavesOnlyTheOpenProfilesFile() throws {
        let store = try makeTempStore()
        let real = try ProfileKeyset(secret: secureRandom(32))
        let decoy = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: real), real),
                               (ProfileSession.emptyData(keys: decoy), decoy)])
        let before = try fileNames(store)
        let decoyData = try store.load(decoy)

        try store.removeOthers(keeping: decoy)

        let after = try fileNames(store)
        #expect(after.count == before.count)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: real).path))
        #expect(try store.load(real) == nil)
        #expect(try store.load(decoy) == decoyData)
        let sizes = Set(try after.map {
            try FileManager.default.attributesOfItem(atPath: store.directory.appending(path: $0).path)[.size] as? Int
        })
        #expect(sizes.count == 1)
    }

    /// After a silent wipe, only the open profile's wallet files may remain.
    @Test func wipeLeavesOnlyTheOpenProfilesWallet() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "zignal-wallet-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let keep = "aaaaaaaaaaaaaaaa", wiped = "bbbbbbbbbbbbbbbb"
        for alias in [keep, wiped] {
            try Data("db".utf8).write(to: root.appending(path: "c_\(alias)_data.db"))
            try Data("wal".utf8).write(to: root.appending(path: "c_\(alias)_data.db-wal"))
            let cache = root.appending(path: "c_\(alias)_fs_cache", directoryHint: .isDirectory)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("block".utf8).write(to: cache.appending(path: "1.block"))
            try fm.createSymbolicLink(at: root.appending(path: "c_\(alias)_sapling-spend.params"),
                                      withDestinationURL: root.appending(path: "missing.params"))
        }
        WalletFiles.removeWallets(except: keep, root: root)
        let left = try fm.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["c_\(keep)_data.db", "c_\(keep)_data.db-wal", "c_\(keep)_fs_cache",
                         "c_\(keep)_sapling-spend.params"])
    }

    /// The SDK keeps one preference per wallet; after a silent wipe only the open profile's
    /// remain, and unrelated preferences are untouched.
    @Test func wipeLeavesOnlyTheOpenProfilesSDKSettings() throws {
        let suite = "zignal-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keep = "aaaaaaaaaaaaaaaa", wiped = "bbbbbbbbbbbbbbbb"
        defaults.set("1.0", forKey: "ud_fixWitnessesLastVersionCall_c_\(keep)")
        defaults.set("1.0", forKey: "ud_fixWitnessesLastVersionCall_c_\(wiped)")
        defaults.set(1, forKey: "c_\(wiped)_someFutureSetting")
        defaults.set(true, forKey: "installed")
        defaults.set("x", forKey: "abc_c_short")

        WalletFiles.removeSDKDefaults(except: keep, defaults: defaults)

        #expect(defaults.string(forKey: "ud_fixWitnessesLastVersionCall_c_\(keep)") == "1.0")
        #expect(defaults.object(forKey: "ud_fixWitnessesLastVersionCall_c_\(wiped)") == nil)
        #expect(defaults.object(forKey: "c_\(wiped)_someFutureSetting") == nil)
        #expect(defaults.bool(forKey: "installed"))
        #expect(defaults.string(forKey: "abc_c_short") == "x")
    }
}

/// A wallet stopped on lock may still be finishing a step; the wipe waits for it.
@MainActor
struct WalletShutdownTests {
    final class Flag { var isSet = false }

    @Test func waitsForStoppedWalletsToFinish() async {
        let finished = Flag()
        WalletShutdown.begin {
            try? await Task.sleep(for: .milliseconds(100))
            finished.isSet = true
        }
        #expect(WalletShutdown.isBusy)
        let settled = await WalletShutdown.waitForAll(timeout: .seconds(5))
        #expect(settled)
        #expect(finished.isSet)
        #expect(!WalletShutdown.isBusy)
    }

    @Test func givesUpAfterTheTimeout() async {
        WalletShutdown.begin { _ = try? await Task.sleep(for: .milliseconds(500)) }
        let settled = await WalletShutdown.waitForAll(timeout: .milliseconds(50))
        #expect(!settled)
        await WalletShutdown.waitForAll(timeout: .seconds(5))
        #expect(!WalletShutdown.isBusy)
    }
}

@MainActor
struct WalletSessionTests {
    @Test func settingsPersistAndDefaultsStayUnwritten() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: keys), keys)])

        let session = try await ProfileSession.open(keys: keys, store: store)
        #expect(session.walletSettings == .standard)
        let own = WalletSettings(servers: [.init(host: "lwd.example.net", port: 9067)], torEnabled: true)
        await session.updateWalletSettings(own)
        #expect(try store.load(keys)?.walletSettings == own)
        let reopened = try await ProfileSession.open(keys: keys, store: store)
        #expect(reopened.walletSettings == own)

        await reopened.updateWalletSettings(.standard)
        #expect(try store.load(keys)?.walletSettings == nil)
        // An empty server list is never saved.
        await reopened.updateWalletSettings(WalletSettings(servers: [], torEnabled: true))
        #expect(reopened.walletSettings == .standard)
    }

    @Test func restoredFlagIsSavedOnlyForRestoredProfiles() async throws {
        let store = try makeTempStore()
        let fresh = try ProfileKeyset(secret: secureRandom(32))
        let restored = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: fresh), fresh),
                               (ProfileSession.emptyData(keys: restored, restored: true), restored)])
        _ = try await ProfileSession.open(keys: fresh, store: store)
        _ = try await ProfileSession.open(keys: restored, store: store)
        #expect(try store.load(fresh)?.walletRestored == nil)
        #expect(try store.load(restored)?.walletRestored == true)
    }

    @Test func interruptedSendShowsAsFailedAndKeepsItsMemos() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        var data = try ProfileSession.emptyData(keys: keys)
        let peer = try secureRandom(32)
        let memos = [Data([0xFF]) + (try secureRandom(511))]
        var message = ChatMessage.outgoing("hello", to: peer, memos: 1)
        message.status = .sending
        message.pendingMemos = memos
        data.contacts = [Contact(id: peer, name: "Contact", added: Date())]
        data.messages = [message]
        try store.reset(with: [(data, keys)])

        let session = try await ProfileSession.open(keys: keys, store: store)
        let reloaded = try #require(session.messages.first)
        #expect(reloaded.status == .failed)
        #expect(reloaded.pendingMemos == memos)
        #expect(try store.load(keys)?.messages.first?.status == .failed)
    }

    @Test func realChatsWaitForTheWallet() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: keys), keys)])
        let session = try await ProfileSession.open(keys: keys, store: store)
        let before = try store.load(keys)

        // No wallet in tests: nothing is encrypted, saved or sent.
        let started = await session.acceptInvite("zignal:AAAA", firstText: "hi")
        #expect(started == nil)
        #expect(session.errorText == ZignalError.walletNotReady.errorDescription)
        #expect(session.contacts.isEmpty)
        let prepared = await session.prepareForChatting()
        #expect(!prepared)
        await #expect(throws: ZignalError.self) { try await session.makeInvite() }
        #expect(try store.load(keys) == before)
    }
}
