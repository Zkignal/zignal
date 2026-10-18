import SwiftUI

struct OnboardingView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "lock.shield")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Zignal").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 16) {
                    Feature(icon: "bubble.left.and.bubble.right",
                            text: "Messages travel inside shielded Zcash transactions.")
                    Feature(icon: "person.crop.circle.badge.xmark",
                            text: "No phone number, no account, no Zignal server.")
                    Feature(icon: "key",
                            text: "Post-quantum handshake and forward secrecy on every message.")
                    Feature(icon: "theatermasks",
                            text: "A duress PIN opens a separate decoy profile.")
                }
                .padding(.horizontal)
                Spacer()
                NavigationLink {
                    PinSetupView()
                } label: {
                    Text("Get started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                NavigationLink("Restore from recovery phrase") {
                    RestorePhraseView()
                }
                Text("Experimental and not audited. Core \(protocolVersion()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 28)
        }
    }
}

struct PinSetupView: View {
    @Environment(AppModel.self) private var model
    /// Set when the real profile comes from a recovery phrase.
    var restore: RestoredProfile?
    @State private var realPin = ""
    @State private var realRepeat = ""
    @State private var duressPin = ""
    @State private var duressRepeat = ""
    @State private var wipeOnDuress = false

    var body: some View {
        Form {
            if restore != nil {
                Section {
                    Label("Recovery phrase accepted", systemImage: "checkmark.seal")
                } footer: {
                    Text("It becomes your real profile. Chat history isn't part of a phrase, so chats start empty. The decoy profile gets a new phrase of its own.")
                }
            }
            Section {
                SecureField("Unlock PIN", text: $realPin).pinInput($realPin)
                SecureField("Repeat unlock PIN", text: $realRepeat).pinInput($realRepeat)
            } header: {
                Text("Unlock PIN")
            } footer: {
                hint(realProblem, otherwise: "At least \(PinPolicy.minLength) digits. If you forget it, restore from your recovery phrase; chat history can't be restored.")
            }

            Section {
                SecureField("Duress PIN", text: $duressPin).pinInput($duressPin)
                SecureField("Repeat duress PIN", text: $duressRepeat).pinInput($duressRepeat)
                Toggle("Also erase real profile", isOn: $wipeOnDuress)
            } header: {
                Text("Duress PIN")
            } footer: {
                hint(duressProblem, otherwise: """
                    If someone forces you to unlock Zignal, enter this PIN instead. It opens a \
                    separate decoy profile. Both profiles are stored the same way, so the files \
                    don't show which one is real. Use the decoy now and then so it looks lived in. \
                    With erase on, the duress PIN also silently destroys your real profile on this phone.
                    """)
            }

            Section {
                Button {
                    Task {
                        await model.createProfiles(realPin: realPin, duressPin: duressPin,
                                                   wipeRealOnDuress: wipeOnDuress, restore: restore)
                    }
                } label: {
                    HStack {
                        Text(restore == nil ? "Create profiles" : "Restore profile")
                        if model.busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!isValid || model.busy)
            } footer: {
                if let error = model.errorText {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Your PINs never leave this phone. Securing them takes a few seconds.")
                }
            }
        }
        .navigationTitle("Set PINs")
        .scrollDismissesKeyboard(.interactively)
    }

    private var realProblem: String? {
        guard !realPin.isEmpty else { return nil }
        if let problem = PinPolicy.problem(realPin) { return PinPolicy.message(problem) }
        if !realRepeat.isEmpty && realRepeat != realPin { return "PINs don't match." }
        return nil
    }

    private var duressProblem: String? {
        guard !duressPin.isEmpty else { return nil }
        if let problem = PinPolicy.problem(duressPin) { return PinPolicy.message(problem) }
        if duressPin == realPin { return "Must be different from your unlock PIN." }
        if !duressRepeat.isEmpty && duressRepeat != duressPin { return "PINs don't match." }
        return nil
    }

    private var isValid: Bool {
        PinPolicy.problem(realPin) == nil && realRepeat == realPin
            && PinPolicy.problem(duressPin) == nil && duressRepeat == duressPin
            && duressPin != realPin
    }

    @ViewBuilder
    private func hint(_ problem: String?, otherwise text: String) -> some View {
        if let problem {
            Text(problem).foregroundStyle(.red)
        } else {
            Text(text)
        }
    }
}

/// Restore: enter a 24-word recovery phrase and roughly when the wallet was created.
struct RestorePhraseView: View {
    @State private var phrase = ""
    @State private var created = Date()
    @State private var restored: RestoredProfile?
    @State private var errorText: String?

    /// Sapling activation (2018-10-29). No Zcash shielded wallet can be older.
    private static let earliest = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2018, month: 10, day: 29)) ?? .distantPast

    private var wordCount: Int {
        phrase.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        Form {
            Section {
                TextField("24 words, separated by spaces", text: $phrase, axis: .vertical)
                    .lineLimit(4...8)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
            } header: {
                Text("Recovery phrase")
            } footer: {
                Text("\(wordCount) of 24 words")
            }
            Section {
                DatePicker("Created", selection: $created, in: Self.earliest...Date(),
                           displayedComponents: .date)
            } header: {
                Text("When was this wallet created?")
            } footer: {
                Text("Pick a date on or before you first used this phrase. Earlier is safe but makes the first sync slower.")
            }
            Section {
                Button("Continue", action: check)
                    .disabled(wordCount != 24)
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Restore")
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(item: $restored) { restore in
            PinSetupView(restore: restore)
        }
    }

    private func check() {
        do {
            let secret = try profileSecretFromPhrase(phrase: phrase)
            errorText = nil
            restored = RestoredProfile(secret: secret, created: created)
        } catch {
            errorText = ZignalError.invalidRecoveryPhrase.errorDescription
        }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Enter PIN").font(.title2.bold())
            SecureField("PIN", text: $pin)
                .pinInput($pin)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.title3.monospaced())
                .padding(12)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .frame(maxWidth: 260)
            Button(action: submit) {
                ZStack {
                    Text("Unlock").opacity(model.busy ? 0 : 1)
                    if model.busy { ProgressView() }
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pin.count < PinPolicy.minLength || model.busy)
            Text(model.errorText ?? " ")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding()
        .onAppear { focused = true }
    }

    private func submit() {
        let entered = pin
        pin = ""
        Task { await model.unlock(pin: entered) }
    }
}
