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
    /// When this profile's wallet was created (or the date picked when restoring it).
    private(set) var walletCreated: Date?
    private(set) var recoveryPhraseShown: Bool
    private(set) var walletSettings: WalletSettings
    /// This profile's Zcash wallet while unlocked. Nil until it starts, and in tests.
    private(set) var wallet: WalletEngine?
    var errorText: String?

    /// Wallet transactions remembered as already read. Older ones drop off; zkw-core's replay
    /// protection still rejects anything that comes back.
    static let maxProcessedTransactions = 5000

    /// Simulated network delay for the demo contact. Tests set this to zero.
    @ObservationIgnored var demoReplyDelay: Duration = .milliseconds(1500)

    @ObservationIgnored private let keys: ProfileKeyset
    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private let inbox: ZkwInbox
    @ObservationIgnored private var demo: ZkwInbox?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var walletRestored: Bool
    @ObservationIgnored private var processedTransactions: [Data]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    private init(_ loaded: LoadedProfile) {
        keys = loaded.keys
        store = loaded.store
        inbox = loaded.inbox
        demo = loaded.demo
        contacts = loaded.data.contacts
        messages = loaded.data.messages
        walletCreated = loaded.data.walletCreated
        recoveryPhraseShown = loaded.data.recoveryPhraseShown ?? false
        walletSettings = loaded.data.walletSettings ?? .standard
        walletRestored = loaded.data.walletRestored ?? false
        processedTransactions = loaded.data.processedTransactions ?? []
    }

    // MARK: - Lifecycle

    /// Contents of a brand-new, empty profile. Used at setup for both profiles. `restored`
    /// marks a profile that came from a recovery phrase, so its wallet scans from
    /// `walletCreated` instead of starting at the current chain height.
    nonisolated static func emptyData(keys: ProfileKeyset, walletCreated: Date = Date(),
                                      restored: Bool = false) throws -> ProfileData {
        let inbox = try ZkwInbox(seed: keys.identitySeed, now: unixNow())
        return ProfileData(inbox: try inbox.exportSealed(stateKey: keys.stateKey),
                           walletCreated: walletCreated, walletRestored: restored ? true : nil)
    }

    /// Opens a profile. Decrypting it, restoring its inbox and re-sealing every profile file
    /// all run off the main thread, so the screen never freezes while a profile opens.
    static func open(keys: ProfileKeyset, store: ProfileStore) async throws -> ProfileSession {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try LoadedProfile.load(keys: keys, store: store)
        }.value
        return ProfileSession(loaded)
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

    /// Called on lock. Stops the wallet, and stops any task still running from saving older
    /// state over newer state.
    func close() {
        isClosed = true
        demo = nil
        wallet?.stop()
        wallet = nil
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

    /// True when `other` are this profile's keys. Used to check a PIN before showing the
    /// recovery phrase, without saying which profile a different PIN belongs to.
    func belongs(to other: ProfileKeyset) -> Bool {
        other.stateKey == keys.stateKey
    }

    // MARK: - Editing

    func markRecoveryPhraseShown() {
        guard !recoveryPhraseShown else { return }
        recoveryPhraseShown = true
        persist()
    }

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
        if contact.isDemo {
            do {
                let out = try inbox.sendText(peer: peer, text: trimmed, now: unixNow())
                try commitOutgoing(.outgoing(trimmed, to: peer, memos: out.memos.count))
                await deliverToDemo(out.memos)
            } catch {
                report(error)
            }
            return
        }
        // Check the wallet first, rather than advance the ratchet for memos it can't send.
        guard let wallet, wallet.canTransact else {
            errorText = ZignalError.walletNotReady.errorDescription
            return
        }
        do {
            let out = try inbox.sendText(peer: peer, text: trimmed, now: unixNow())
            var message = ChatMessage.outgoing(trimmed, to: peer, memos: out.memos.count)
            message.status = .sending
            message.pendingMemos = out.memos
            try commitOutgoing(message) // saved before anything leaves the phone
            await transmit(message.id, memos: out.memos, to: out.toAddress)
        } catch {
            report(error)
        }
    }

    /// Sends a failed message again with the same encrypted memos. A copy that did reach the
    /// chain is dropped by the contact's replay protection, so this never shows twice.
    func retry(_ id: UUID) async {
        guard !isClosed, let message = messages.first(where: { $0.id == id }),
              message.status == .failed, let memos = message.pendingMemos,
              let address = try? inbox.contactAddress(peer: message.peer) else { return }
        guard let wallet, wallet.canTransact else {
            errorText = ZignalError.walletNotReady.errorDescription
            return
        }
        updateMessage(id) { $0.status = .sending }
        await transmit(id, memos: memos, to: address)
    }

    /// Broadcasts a saved message and records the outcome.
    private func transmit(_ id: UUID, memos: [Data], to address: Data) async {
        do {
            guard let wallet else { throw ZignalError.walletNotReady }
            let text = String(decoding: address, as: UTF8.self)
            // The address came from a contact's invite and goes into a payment request, so it
            // must be a plain shielded address and nothing else (no extra request parameters).
            guard PaymentRequest.isShieldedAddress(text) else { throw ZignalError.invalidAddress }
            let txid = try await wallet.send(memos: memos, to: text)
            updateMessage(id) {
                $0.status = .sent
                $0.txid = txid
            }
        } catch {
            updateMessage(id) { $0.status = .failed }
            report(error)
        }
        if !isClosed { persist() }
    }

    // MARK: - Wallet

    /// Starts this profile's wallet. Called after unlock with the profile's wallet seed.
    func startWallet(seed: Data) async {
        guard !isClosed, wallet == nil else { return }
        let engine = WalletEngine(seed: seed,
                                  alias: keys.subkeyBytes(KeyLabel.walletAlias, count: 8).hexString,
                                  settings: walletSettings,
                                  restoreFrom: walletRestored ? walletCreated : nil)
        engine.onChange = { [weak self] in await self?.refreshFromWallet() }
        wallet = engine
        await engine.start()
    }

    func updateWalletSettings(_ settings: WalletSettings) async {
        guard !isClosed, settings != walletSettings, !settings.servers.isEmpty else { return }
        walletSettings = settings
        persist()
        await wallet?.apply(settings)
    }

    /// Splits the balance into several notes so messages can go out back to back.
    func prepareForChatting() async -> Bool {
        guard !isClosed, let wallet, wallet.canTransact else {
            errorText = ZignalError.walletNotReady.errorDescription
            return false
        }
        do {
            _ = try await wallet.prepareForChatting()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Reads new messages and delivery updates from the wallet. Overlapping calls collapse into
    /// one more pass, so it is safe to call whenever the wallet reports a change.
    func refreshFromWallet() async {
        guard !isClosed, let wallet else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                let snapshot = try await wallet.snapshot(skipping: Set(processedTransactions))
                guard !isClosed else { return }
                var changed = false
                for item in snapshot.incoming where !processedTransactions.contains(item.txid) {
                    // Read at the time it was sent, not now: the core matches each message to
                    // its chat by a tag that changes daily, so a message read days later
                    // would otherwise be dropped.
                    var read = false
                    for memo in item.memos {
                        if let event = try inbox.receive(memo: memo, now: item.time) {
                            handle(event, at: Date(timeIntervalSince1970: TimeInterval(item.time)))
                            read = true
                        }
                    }
                    // Until the wallet has scanned every block, a transaction with nothing
                    // readable may be a reply whose first message hasn't been found yet. It is
                    // read again on the next pass instead of being set aside.
                    guard read || snapshot.complete else { continue }
                    processedTransactions.append(item.txid)
                    changed = true
                }
                if processedTransactions.count > Self.maxProcessedTransactions {
                    processedTransactions.removeFirst(processedTransactions.count - Self.maxProcessedTransactions)
                }
                if updateDelivery(mined: snapshot.mined, expired: snapshot.expired) { changed = true }
                if changed { try save() }
            } catch {
                report(error)
                return
            }
        } while refreshAgain && !isClosed
    }

    /// Marks sent messages delivered once mined, or failed if they expired unmined.
    private func updateDelivery(mined: Set<Data>, expired: Set<Data>) -> Bool {
        var changed = false
        for i in messages.indices where messages[i].outgoing && messages[i].status == .sent {
            guard let txid = messages[i].txid else { continue }
            if mined.contains(txid) {
                messages[i].status = .delivered
                messages[i].pendingMemos = nil
                changed = true
            } else if expired.contains(txid) {
                messages[i].status = .failed
                changed = true
            }
        }
        return changed
    }

    // MARK: - Invites

    /// An invite for someone to start a chat with us, as text for a QR code or a message. It
    /// carries a fresh address that only this contact will use.
    func makeInvite() async throws -> String {
        guard !isClosed, let wallet, wallet.canTransact else { throw ZignalError.walletNotReady }
        let address = try await wallet.newAddress()
        guard !isClosed else { throw CancellationError() }
        let invite = try inbox.createInvite(myAddress: Data(address.utf8))
        try save() // the inbox must remember this invite to answer it later
        return InviteCode.encode(invite)
    }

    /// Starts a chat from a contact's invite and sends the first message. Returns the contact.
    func acceptInvite(_ code: String, firstText: String) async -> Data? {
        let text = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isClosed, !text.isEmpty else { return nil }
        guard let wallet, wallet.canTransact else {
            errorText = ZignalError.walletNotReady.errorDescription
            return nil
        }
        do {
            guard let invite = InviteCode.decode(code), let inviter = InviteCode.inviterID(invite) else {
                throw ZignalError.invalidInvite
            }
            // Checked before any keys are made: the first message goes to this address.
            guard let theirs = InviteCode.address(invite), PaymentRequest.isShieldedAddress(theirs) else {
                throw ZignalError.invalidAddress
            }
            guard inviter != (try inbox.myId()) else { throw ZignalError.ownInvite }
            guard text.utf8.count <= Self.maxTextBytes else { throw ZignalError.messageTooLong }
            let address = try await wallet.newAddress()
            guard !isClosed else { return nil }
            let out = try inbox.startFromInvite(invite: invite, myAddress: Data(address.utf8), firstText: text)
            let isNew = contact(inviter) == nil
            if isNew { contacts.append(Contact(id: inviter, name: "New contact", added: Date())) }
            var message = ChatMessage.outgoing(text, to: inviter, memos: out.memos.count)
            message.status = .sending
            message.pendingMemos = out.memos
            do {
                try commitOutgoing(message)
            } catch {
                if isNew { contacts.removeAll { $0.id == inviter } }
                throw error
            }
            await transmit(message.id, memos: out.memos, to: out.toAddress)
            return inviter
        } catch {
            report(error)
            return nil
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

    /// `date`: when the message was sent, as far as we know (its block time).
    private func handle(_ event: ZkwEvent, at date: Date = Date()) {
        switch event {
        case .newSession(let peer, let text), .message(let peer, let text):
            if contact(peer) == nil {
                contacts.append(Contact(id: peer, name: "New contact", added: Date()))
            }
            messages.append(.incoming(text, from: peer, date: date))
        case .receipt, .reaction, .closed, .request, .bundle:
            break // Not used yet: contacts start from invites, and receipts would cost fees.
        }
    }

    // MARK: - Saving

    /// Records an outgoing message and saves. If saving fails the message is removed again
    /// and the error is thrown, so the caller never sends memos for unsaved state.
    private func updateMessage(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

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
        var data = ProfileData(inbox: Data(), contacts: contacts, messages: messages,
                               walletCreated: walletCreated,
                               recoveryPhraseShown: recoveryPhraseShown,
                               walletRestored: walletRestored ? true : nil,
                               walletSettings: walletSettings == .standard ? nil : walletSettings,
                               processedTransactions: processedTransactions)
        try data.seal(inbox: inbox, demo: demo, keys: keys)
        try store.save(data, keys)
    }

    private func persist() {
        do { try save() } catch { report(error) }
    }

    private func report(_ error: Error) {
        errorText = AppModel.describe(error)
    }
}

/// A profile read from disk and ready to show, prepared off the main thread by
/// `ProfileSession.open`.
///
/// The generated bindings don't mark `ZkwInbox` as Sendable, but zkw-ffi guards every call
/// into an inbox with a mutex, so handing one from a background task to the main actor is safe.
private struct LoadedProfile: @unchecked Sendable {
    let keys: ProfileKeyset
    let store: ProfileStore
    let inbox: ZkwInbox
    let demo: ZkwInbox?
    let data: ProfileData

    static func load(keys: ProfileKeyset, store: ProfileStore) throws -> LoadedProfile {
        let now = unixNow()
        var data: ProfileData
        let inbox: ZkwInbox
        let demo: ZkwInbox?
        if let saved = try store.load(keys) {
            data = saved
            inbox = try ZkwInbox.restore(identitySeed: keys.identitySeed,
                                         stateKey: keys.stateKey, sealedState: saved.inbox)
            demo = restoreDemo(keys: keys, data: &data)
            // A send cut short by a lock or crash may or may not have reached the network.
            // Show it as failed; sending it again is safe (see `retry`).
            for i in data.messages.indices where data.messages[i].status == .sending {
                data.messages[i].status = .failed
            }
        } else {
            // No file for this profile on this device (for example after restoring a device
            // backup, which never contains chat state). Start with an empty inbox.
            data = ProfileData(inbox: Data())
            inbox = try ZkwInbox(seed: keys.identitySeed, now: now)
            demo = nil
        }
        _ = try inbox.rotatePrekeysIfDue(now: now)
        // Saving on every open re-seals all profile files, whichever profile was opened.
        try data.seal(inbox: inbox, demo: demo, keys: keys)
        try store.save(data, keys)
        return LoadedProfile(keys: keys, store: store, inbox: inbox, demo: demo, data: data)
    }

    /// Restores the demo contact. If its state is missing, damaged, or it never received our
    /// first message (say the app was killed right after saving), the demo contact is removed
    /// so it can be started again. It never blocks opening the profile.
    private static func restoreDemo(keys: ProfileKeyset, data: inout ProfileData) -> ZkwInbox? {
        if let state = data.demoContact,
           let bot = try? ZkwInbox.restore(identitySeed: keys.subkeyBytes(KeyLabel.demoIdentity),
                                           stateKey: keys.subkeyBytes(KeyLabel.demoState),
                                           sealedState: state),
           (try? bot.contacts())?.isEmpty == false {
            return bot
        }
        let demoIds = Set(data.contacts.filter(\.isDemo).map(\.id))
        data.contacts.removeAll { demoIds.contains($0.id) }
        data.messages.removeAll { demoIds.contains($0.peer) }
        return nil
    }
}

private extension ProfileData {
    /// Seals the live inbox (and demo contact, if any) into this record before it's written.
    mutating func seal(inbox: ZkwInbox, demo: ZkwInbox?, keys: ProfileKeyset) throws {
        self.inbox = try inbox.exportSealed(stateKey: keys.stateKey)
        demoContact = try demo?.exportSealed(stateKey: keys.subkeyBytes(KeyLabel.demoState))
    }
}
