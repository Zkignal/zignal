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

    @Test func missingFileLoadsAsNil() throws {
        let store = try makeTempStore()
        #expect(try store.load(ProfileKeyset(secret: secureRandom(32))) == nil)
    }
}

/// Runs Argon2id (64 MiB) several times, so these take a few seconds.
struct VaultTests {
    @Test func realDuressAndWrongPin() throws {
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471", wipeRealOnDuress: false)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "583914").secret == created.realSecret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "260471").secret == created.decoySecret)
        #expect(try VaultOps.unlock(vault: created.vault, pin: "000000").secret == nil)
        #expect(created.realSecret != created.decoySecret)
    }

    @Test func duressPinCanSilentlyEraseRealProfile() throws {
        let created = try VaultOps.create(realPin: "583914", duressPin: "260471", wipeRealOnDuress: true)
        let duress = try VaultOps.unlock(vault: created.vault, pin: "260471")
        #expect(duress.secret == created.decoySecret)
        #expect(duress.vault != created.vault)
        #expect(duress.vault.count == created.vault.count)
        #expect(try VaultOps.unlock(vault: duress.vault, pin: "583914").secret == nil)
        #expect(try VaultOps.unlock(vault: duress.vault, pin: "260471").secret == created.decoySecret)
    }
}

@MainActor
struct ProfileSessionTests {
    @Test func demoChatRoundTripSurvivesRestart() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        try store.reset(with: [(ProfileSession.emptyData(keys: keys), keys)])

        let session = try ProfileSession.open(keys: keys, store: store)
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
        let reopened = try ProfileSession.open(keys: keys, store: store)
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

        let session = try ProfileSession.open(keys: real, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        #expect(session.contacts.count == 1)

        let other = try ProfileSession.open(keys: decoy, store: store)
        #expect(other.contacts.isEmpty)
        #expect(other.messages.isEmpty)
    }

    @Test func closedSessionNeverSavesAgain() async throws {
        let store = try makeTempStore()
        let keys = try ProfileKeyset(secret: secureRandom(32))
        let session = try ProfileSession.open(keys: keys, store: store)
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
        let session = try ProfileSession.open(keys: keys, store: store)
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
        let session = try ProfileSession.open(keys: keys, store: store)
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
        let session = try ProfileSession.open(keys: keys, store: store)
        session.demoReplyDelay = .zero
        await session.startDemoChat()
        let demo = try #require(session.contacts.first)
        await session.send(String(repeating: "y", count: ProfileSession.maxTextBytes), to: demo.id)
        #expect(session.errorText == nil)
        let sent = try #require(session.messages(with: demo.id).last(where: { $0.outgoing }))
        #expect(sent.memoCount > 1)
        #expect(sent.memoCount <= 15)
    }
}
