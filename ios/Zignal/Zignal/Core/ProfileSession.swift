import Foundation
import Observation

/// One unlocked profile: the zkw-core inbox plus local chat history.
///
/// State is saved to the encrypted profile file after every change, and always before
/// anything leaves the device, so a crash can never cause ratchet keys to be reused.
/// On lock the session is closed and dropped; a closed session never saves or sends again.
@MainActor
@Observable
final class ProfileSession {
    /// Longest message accepted, in UTF-8 bytes. Fits the 15-memo limit with room to spare.
    static let maxTextBytes = 4000

    private(set) var contacts: [Contact]
    private(set) var messages: [ChatMessage]
    var errorText: String?

    /// Simulated network delay for the demo contact. Tests set this to zero.
    @ObservationIgnored var demoReplyDelay: Duration = .milliseconds(1500)

    @ObservationIgnored private let keys: ProfileKeyset
    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private let inbox: ZkwInbox
    @ObservationIgnored private var demo: ZkwInbox?
    @ObservationIgnored private var isClosed = false

    private init(keys: ProfileKeyset, store: ProfileStore, inbox: ZkwInbox, data: ProfileData) {
        self.keys = keys
        self.store = store
        self.inbox = inbox
        contacts = data.contacts
        messages = data.messages
    }

    // MARK: - Lifecycle

    /// Contents of a brand-new, empty profile. Used at setup for both profiles.
    static func emptyData(keys: ProfileKeyset) throws -> ProfileData {
        let inbox = try ZkwInbox(seed: keys.identitySeed, now: unixNow())
        return ProfileData(inbox: try inbox.exportSealed(stateKey: keys.stateKey))
    }

    static func open(keys: ProfileKeyset, store: ProfileStore) throws -> ProfileSession {
        let now = unixNow()
        let session: ProfileSession
        if let saved = try store.load(keys) {
            let inbox = try ZkwInbox.restore(identitySeed: keys.identitySeed,
                                             stateKey: keys.stateKey, sealedState: saved.inbox)
            session = ProfileSession(keys: keys, store: store, inbox: inbox, data: saved)
            session.restoreDemo(from: saved.demoContact)
        } else {
            // No file for this profile on this device (for example after restoring a device
            // backup, which never contains chat state). Start with an empty inbox.
            let inbox = try ZkwInbox(seed: keys.identitySeed, now: now)
            session = ProfileSession(keys: keys, store: store, inbox: inbox,
                                     data: ProfileData(inbox: Data()))
        }
        _ = try session.inbox.rotatePrekeysIfDue(now: now)
        try session.save()
        return session
    }

    // MARK: - Reading

    var hasDemoContact: Bool { contacts.contains { $0.isDemo } }

    func contact(_ peer: Data) -> Contact? {
        contacts.first { $0.id == peer }
    }

    func messages(with peer: Data) -> [ChatMessage] {
        messages.filter { $0.peer == peer }
    }

    func lastMessage(with peer: Data) -> ChatMessage? {
        messages.last { $0.peer == peer }
    }

    /// Called on lock. Stops any task still running from saving older state over newer state.
    func close() {
        isClosed = true
        demo = nil
    }

    /// Contacts with the most recent conversation first.
    var contactsByRecent: [Contact] {
        contacts.sorted {
            (lastMessage(with: $0.id)?.date ?? $0.added) > (lastMessage(with: $1.id)?.date ?? $1.added)
        }
    }

    func safetyNumber(for peer: Data) -> String? {
        try? inbox.safetyNumber(peer: peer)
    }

    // MARK: - Editing

    func rename(_ peer: Data, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty, let i = contacts.firstIndex(where: { $0.id == peer }) else { return }
        contacts[i].name = trimmed
        persist()
    }

    func setVerified(_ peer: Data, _ verified: Bool) {
        guard let i = contacts.firstIndex(where: { $0.id == peer }) else { return }
        contacts[i].verified = verified
        persist()
    }

    // MARK: - Sending

    func send(_ text: String, to peer: Data) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isClosed, !trimmed.isEmpty, let contact = contact(peer) else { return }
        guard trimmed.utf8.count <= Self.maxTextBytes else {
            errorText = ZignalError.messageTooLong.errorDescription
            return
        }
        // Real contacts need the wallet to send transactions. Until it exists, refuse
        // rather than advance the ratchet for memos that would never be sent.
        guard contact.isDemo else {
            errorText = "Sending to real contacts arrives with the wallet."
            return
        }
        do {
            let out = try inbox.sendText(peer: peer, text: trimmed, now: unixNow())
            try commitOutgoing(.outgoing(trimmed, to: peer, memos: out.memos.count))
            await deliverToDemo(out.memos)
        } catch {
            report(error)
        }
    }

    // MARK: - Demo contact

    /// Starts a chat with a contact that lives on this phone. Every message still goes through
    /// the full protocol: post-quantum handshake, Double Ratchet, 512-byte memos and back.
    /// Nothing touches the network.
    func startDemoChat() async {
        guard !isClosed, !hasDemoContact else { return }
        do {
            let now = unixNow()
            let bot = try ZkwInbox(seed: keys.subkeyBytes(KeyLabel.demoIdentity), now: now)
            let invite = try bot.createInvite(myAddress: Data("demo:contact".utf8))
            let first = "Hi! Testing Zignal."
            let out = try inbox.startFromInvite(invite: invite, myAddress: Data("demo:me".utf8),
                                                firstText: first)
            let botId = try bot.myId()
            contacts.append(Contact(id: botId, name: "Demo contact", isDemo: true, added: Date()))
            demo = bot
            do {
                try commitOutgoing(.outgoing(first, to: botId, memos: out.memos.count))
            } catch {
                contacts.removeAll { $0.id == botId }
                demo = nil
                throw error
            }
            await deliverToDemo(out.memos)
        } catch {
            report(error)
        }
    }

    /// Restores the demo contact. If its state is missing, damaged, or it never received our
    /// first message (say the app was killed right after saving), the demo contact is removed
    /// so it can be started again. It never blocks opening the profile.
    private func restoreDemo(from state: Data?) {
        if let state,
           let bot = try? ZkwInbox.restore(identitySeed: keys.subkeyBytes(KeyLabel.demoIdentity),
                                           stateKey: keys.subkeyBytes(KeyLabel.demoState),
                                           sealedState: state),
           (try? bot.contacts())?.isEmpty == false {
            demo = bot
            return
        }
        let demoIds = Set(contacts.filter(\.isDemo).map(\.id))
        contacts.removeAll { demoIds.contains($0.id) }
        messages.removeAll { demoIds.contains($0.peer) }
    }

    /// The demo contact decrypts our memos and replies with what it read.
    private func deliverToDemo(_ memos: [Data]) async {
        if demoReplyDelay > .zero { try? await Task.sleep(for: demoReplyDelay) }
        guard !isClosed, let bot = demo else { return }
        do {
            let now = unixNow()
            var decrypted: (peer: Data, text: String)?
            for memo in memos {
                switch try bot.receive(memo: memo, now: now) {
                case .newSession(let peer, let text)?, .message(let peer, let text)?:
                    decrypted = (peer, text)
                default:
                    break
                }
            }
            guard let decrypted else { return }
            let count = memos.count == 1 ? "1 memo" : "\(memos.count) memos"
            let reply = "Decrypted your message (\(count)): \u{201C}\(decrypted.text)\u{201D}"
            let out = try bot.sendText(peer: decrypted.peer, text: reply, now: now)
            for memo in out.memos {
                if let event = try inbox.receive(memo: memo, now: now) { handle(event) }
            }
            try save()
        } catch {
            report(error)
        }
    }

    // MARK: - Receiving

    private func handle(_ event: ZkwEvent) {
        switch event {
        case .newSession(let peer, let text), .message(let peer, let text):
            if contact(peer) == nil {
                contacts.append(Contact(id: peer, name: "New contact", added: Date()))
            }
            messages.append(.incoming(text, from: peer))
        case .receipt, .reaction, .closed, .request, .bundle:
            break // Wired up with real contacts in the wallet step.
        }
    }

    // MARK: - Saving

    /// Records an outgoing message and saves. If saving fails the message is removed again
    /// and the error is thrown, so the caller never sends memos for unsaved state.
    private func commitOutgoing(_ message: ChatMessage) throws {
        messages.append(message)
        do {
            try save()
        } catch {
            messages.removeAll { $0.id == message.id }
            throw error
        }
    }

    private func save() throws {
        guard !isClosed else { throw CancellationError() }
        var data = ProfileData(inbox: try inbox.exportSealed(stateKey: keys.stateKey),
                               contacts: contacts, messages: messages)
        if let demo {
            data.demoContact = try demo.exportSealed(stateKey: keys.subkeyBytes(KeyLabel.demoState))
        }
        try store.save(data, keys)
    }

    private func persist() {
        do { try save() } catch { report(error) }
    }

    private func report(_ error: Error) {
        errorText = AppModel.describe(error)
    }
}
