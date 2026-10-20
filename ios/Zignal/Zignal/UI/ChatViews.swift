import SwiftUI

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    private let session: ProfileSession
    @State private var showPhrase = false
    @State private var showInvite = false
    @State private var addContact = false
    @State private var path: [Data] = []

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !session.recoveryPhraseShown {
                    Section {
                        Button {
                            showPhrase = true
                        } label: {
                            Label("Back up your recovery phrase", systemImage: "key")
                        }
                    } footer: {
                        Text("Without it, a lost phone means a lost wallet.")
                    }
                }
                WalletSection(session: session)
                if session.contacts.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Add a contact from New chat with an invite, or try the encrypted chat with a demo contact that lives on this phone and needs no ZEC.")
                    } actions: {
                        Button("Start demo chat") { Task { await session.startDemoChat() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(session.contactsByRecent) { contact in
                        NavigationLink(value: contact.id) {
                            ChatRow(contact: contact, last: session.lastMessage(with: contact.id))
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: Data.self) { peer in
                ConversationView(session: session, peer: peer)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Lock", systemImage: "lock") { model.lock() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Recovery phrase", systemImage: "key") { showPhrase = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Show my invite", systemImage: "qrcode") { showInvite = true }
                            .disabled(!walletReady)
                        Button("Scan or paste an invite", systemImage: "qrcode.viewfinder") { addContact = true }
                            .disabled(!walletReady)
                        Divider()
                        Button("Start demo chat", systemImage: "sparkles") {
                            Task { await session.startDemoChat() }
                        }
                        .disabled(session.hasDemoContact)
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showPhrase) {
                RecoveryPhraseView(session: session)
                    .environment(model)
            }
            .sheet(isPresented: $showInvite) {
                ShowInviteView(session: session)
            }
            .sheet(isPresented: $addContact) {
                AcceptInviteView(session: session) { peer in path = [peer] }
            }
        }
        // One alert for the whole stack, so a pushed screen never shows a second copy.
        .errorAlert(session)
    }

    /// Invites need a new address, so the wallet must be running.
    private var walletReady: Bool { session.wallet?.canTransact == true }
}

private struct ChatRow: View {
    let contact: Contact
    let last: ChatMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(contact.name).font(.headline)
                if contact.verified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Verified")
                }
                Spacer()
                if let last {
                    Text(last.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(last?.text ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct ConversationView: View {
    let session: ProfileSession
    let peer: Data
    @State private var draft = ""
    @State private var showInfo = false

    var body: some View {
        let thread = session.messages(with: peer)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(thread) { message in
                        MessageBubble(message: message, showsStatus: !isDemo) {
                            Task { await session.retry(message.id) }
                        }
                        .id(message.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.count) {
                if let last = session.messages(with: peer).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(session.contact(peer)?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Contact info", systemImage: "info.circle") { showInfo = true }
        }
        .sheet(isPresented: $showInfo) {
            ContactInfoView(session: session, peer: peer)
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let walletHint {
                Text(walletHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if draft.utf8.count > ProfileSession.maxTextBytes * 3 / 4 {
                Text("\(draft.utf8.count) / \(ProfileSession.maxTextBytes)")
                    .font(.caption2)
                    .foregroundStyle(tooLong ? Color.red : Color.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Autocorrect off: what you type here shouldn't feed the keyboard's learned words.
                TextField("Message", text: $draft, axis: .vertical)
                    .autocorrectionDisabled()
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 18))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var tooLong: Bool { draft.utf8.count > ProfileSession.maxTextBytes }

    private var isDemo: Bool { session.contact(peer)?.isDemo == true }

    /// The network fee for a one-memo message (ZIP-317: two actions at 5,000 zatoshis).
    private static let smallestFee: Int64 = 10_000

    private var canSend: Bool {
        guard session.contact(peer) != nil, !tooLong,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isDemo || walletHint == nil
    }

    /// Why a real message can't go out yet, if it can't. A longer message can still fail for
    /// lack of funds; it then shows as not sent, with tap to send again.
    private var walletHint: String? {
        guard !isDemo, session.contact(peer) != nil else { return nil }
        guard let wallet = session.wallet else {
            return "The wallet is starting. Sending turns on when it's ready."
        }
        if case .failed = wallet.phase {
            return "The wallet stopped with an error. See Wallet on the chat list."
        }
        guard wallet.canTransact else {
            return "The wallet is starting. Sending turns on when it's ready."
        }
        if wallet.spendable < Self.smallestFee {
            return wallet.pending > 0
                ? "Waiting for ZEC to confirm before the next message can go out."
                : "Add funds to send: each message costs about 0.0001 ZEC."
        }
        return nil
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await session.send(text, to: peer) }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    /// Real contacts show sending and delivery; demo messages never touch the network.
    let showsStatus: Bool
    let retry: () -> Void

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 48) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
                // Text(String) renders verbatim: no Markdown, so received text can't inject links.
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(message.outgoing ? Color.white : Color.primary)
                    .background(message.outgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: 16))
                if showsStatus && message.outgoing && message.status == .failed {
                    Button(action: retry) {
                        Label("Not sent. Tap to send again.", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                } else {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !message.outgoing { Spacer(minLength: 48) }
        }
    }

    private var caption: String {
        let time = message.date.formatted(date: .omitted, time: .shortened)
        guard message.outgoing else { return time }
        let memos = message.memoCount == 1 ? "1 memo" : "\(message.memoCount) memos"
        guard showsStatus else { return "\(time), \(memos)" }
        switch message.status {
        case .sending: return "\(time), \(memos), sending"
        case .sent: return "\(time), \(memos), sent"
        case .delivered: return "\(time), \(memos), delivered"
        case .failed, .received: return "\(time), \(memos)"
        }
    }
}

struct ContactInfoView: View {
    let session: ProfileSession
    let peer: Data
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Only stored on this phone, encrypted. Never sent.")
                }
                Section {
                    if let number = session.safetyNumber(for: peer) {
                        SafetyNumberGrid(number: number)
                    }
                    Toggle("Verified", isOn: verified)
                } header: {
                    Text("Safety number")
                } footer: {
                    Text("Compare these 60 digits with your contact in person or on a call. If they match, nobody is intercepting your chat, and you can mark the contact as verified.")
                }
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        session.rename(peer, to: name)
                        dismiss()
                    }
                }
            }
            .onAppear { name = session.contact(peer)?.name ?? "" }
        }
    }

    private var verified: Binding<Bool> {
        Binding(get: { session.contact(peer)?.verified ?? false },
                set: { session.setVerified(peer, $0) })
    }
}

private extension View {
    func errorAlert(_ session: ProfileSession) -> some View {
        alert("Something went wrong", isPresented: Binding(
            get: { session.errorText != nil },
            set: { if !$0 { session.errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorText ?? "")
        }
    }
}
