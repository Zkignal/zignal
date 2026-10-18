import SwiftUI

/// Shows the open profile's recovery phrase after asking for its PIN again.
/// Works the same in the real and decoy profiles: each shows its own phrase.
struct RecoveryPhraseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let session: ProfileSession
    @State private var pin = ""
    @State private var words: [String] = []
    @State private var errorText: String?
    @State private var checking = false
    @FocusState private var focused: Bool

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack {
            Group {
                if words.isEmpty {
                    pinPrompt
                } else {
                    phrase
                }
            }
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(checking)
    }

    private var pinPrompt: some View {
        Form {
            Section {
                SecureField("PIN", text: $pin)
                    .pinInput($pin)
                    .focused($focused)
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Show recovery phrase")
                        if checking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(pin.count < PinPolicy.minLength || checking)
            } header: {
                Text("Enter your PIN")
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    Text("Make sure nobody can see your screen.")
                }
            }
        }
        .onAppear { focused = true }
    }

    private var phrase: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhraseGrid(words: words)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Write these 24 words on paper, in order.", systemImage: "pencil")
                    Label("Never photograph them or store them online.", systemImage: "eye.slash")
                    Label("Anyone with these words controls this profile's wallet and identity.",
                          systemImage: "exclamationmark.triangle")
                    Label("They restore the wallet, not your chats.",
                          systemImage: "bubble.left.and.bubble.right")
                }
                .font(.callout)
            }
            .padding()
        }
        .privacySensitive()
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let entered = pin
        pin = ""
        switch await model.revealRecoveryPhrase(pin: entered, for: session) {
        case .phrase(let text):
            errorText = nil
            words = text.split(separator: " ").map(String.init)
            session.markRecoveryPhraseShown()
        case .wrongPin:
            errorText = "Wrong PIN."
        case .refused(let message):
            errorText = message
        }
    }
}

/// 24 numbered words in two columns, read left to right.
struct PhraseGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { item in
                HStack(spacing: 8) {
                    Text("\(item.offset + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(item.element)
                        .font(.body.monospaced())
                }
            }
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}
