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
                            text: "A duress PIN opens a decoy profile. A panic PIN also erases the real one.")
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
    @State private var panicPin = ""
    @State private var panicRepeat = ""
    @State private var panicUnderstood = false

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
                PinRole(number: 1, name: "Unlock PIN", text: "opens your real profile.")
                PinRole(number: 2, name: "Duress PIN", text: "opens a decoy profile if someone forces you.")
                PinRole(number: 3, name: "Panic PIN", text: "erases your real profile, then opens the decoy.")
            } header: {
                Text("You'll set 3 different PINs")
            }

            Section {
                SecureField("Unlock PIN", text: $realPin).pinInput($realPin)
                SecureField("Repeat unlock PIN", text: $realRepeat).pinInput($realRepeat)
            } header: {
                Text("1. Unlock PIN")
            } footer: {
                hint(realProblem, otherwise: """
                    Opens your real profile. At least \(PinPolicy.minLength) digits.
                    Forgot it? Restore with your 24-word recovery phrase. Chats can't be restored.
                    """)
            }

            Section {
                SecureField("Duress PIN", text: $duressPin).pinInput($duressPin)
                SecureField("Repeat duress PIN", text: $duressRepeat).pinInput($duressRepeat)
            } header: {
                Text("2. Duress PIN")
            } footer: {
                hint(duressProblem, otherwise: """
                    Use this if someone forces you to open Zignal.
                    • Opens a decoy profile with its own wallet and chats.
                    • Never deletes anything.
                    • Both profiles are stored the same way, so a quick look at the phone won't \
                    show which one is real.
                    Tip: open the decoy now and then and keep a little ZEC in it, so it looks like \
                    an account you really use.
                    """)
            }

            Section {
                SecureField("Panic PIN", text: $panicPin).pinInput($panicPin)
                SecureField("Repeat panic PIN", text: $panicRepeat).pinInput($panicRepeat)
                Toggle("I understand this can't be undone", isOn: $panicUnderstood)
            } header: {
                Text("3. Panic PIN")
            } footer: {
                hint(panicProblem, otherwise: """
                    Your last resort. It can't be undone.
                    • Quietly erases your real profile from this phone: its chats, wallet data and \
                    unlock PIN.
                    • Then opens the decoy as if nothing happened.
                    • Your real funds come back only with your 24-word recovery phrase. Keep it \
                    written down, away from this phone.
                    • Erased chats are gone for good.
                    Pick a PIN you won't type by accident.
                    """)
            }

            Section {
                Button {
                    Task {
                        await model.createProfiles(realPin: realPin, duressPin: duressPin,
                                                   panicPin: panicPin, restore: restore)
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

    private var panicProblem: String? {
        guard !panicPin.isEmpty else { return nil }
        if let problem = PinPolicy.problem(panicPin) { return PinPolicy.message(problem) }
        if panicPin == realPin { return "Must be different from your unlock PIN." }
        if panicPin == duressPin { return "Must be different from your duress PIN." }
        if !panicRepeat.isEmpty && panicRepeat != panicPin { return "PINs don't match." }
        return nil
    }

    private var isValid: Bool {
        PinPolicy.problem(realPin) == nil && realRepeat == realPin
            && PinPolicy.problem(duressPin) == nil && duressRepeat == duressPin
            && PinPolicy.problem(panicPin) == nil && panicRepeat == panicPin
            && Set([realPin, duressPin, panicPin]).count == 3
            && panicUnderstood
    }

    /// The text under a PIN: the problem in red if there is one, otherwise the explanation.
    /// One size above the usual footnote, so it's easier to read.
    @ViewBuilder
    private func hint(_ problem: String?, otherwise text: String) -> some View {
        Group {
            if let problem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text(text)
            }
        }
        .font(.subheadline)
    }
}

/// One line of the overview at the top of the Set PINs screen.
private struct PinRole: View {
    let number: Int
    let name: String
    let text: String

    var body: some View {
        Label {
            Text("\(Text(name).bold()): \(text)")
        } icon: {
            Image(systemName: "\(number).circle.fill").foregroundStyle(.tint)
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
            // Redrawn every second so the wrong-PIN countdown is live.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = model.remainingWait(at: context.date)
                VStack(spacing: 20) {
                    Button(action: submit) {
                        ZStack {
                            Text("Unlock").opacity(model.busy ? 0 : 1)
                            if model.busy { ProgressView() }
                        }
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pin.count < PinPolicy.minLength || model.busy || wait > 0)
                    PinStatus(wait: wait, checking: model.busy, error: model.errorText)
                }
            }
            Spacer()
            Spacer()
        }
        .padding()
        .onAppear {
            model.refreshLockout()
            focused = true
        }
        .resetsPinEntry($pin, focused: $focused)
    }

    private func submit() {
        let entered = pin
        pin = ""
        Task { await model.unlock(pin: entered) }
    }
}
