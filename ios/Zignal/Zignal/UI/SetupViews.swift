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
    /// Set when profiles come from recovery phrases (the real one, the decoy, or both).
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
            if let restore {
                Section {
                    Label(restore.realSecret != nil && restore.decoySecret != nil
                          ? "Recovery phrases accepted" : "Recovery phrase accepted",
                          systemImage: "checkmark.seal")
                } footer: {
                    Text(restore.realSecret != nil && restore.decoySecret != nil
                         ? "Both profiles come back: the unlock PIN (PIN 1) opens the real one, the duress PIN (PIN 2) the decoy. Chat history isn't part of a phrase, so chats start empty. After setup the real profile opens."
                         : restore.decoySecret != nil
                         ? "It becomes your decoy profile, the one the duress PIN (PIN 2) opens. Chat history isn't part of a phrase, so chats start empty. The real profile is new and gets a phrase of its own. After setup the real profile opens: lock, then enter the duress PIN to see the restored one."
                         : "It becomes your real profile, the one the unlock PIN (PIN 1) opens. Chat history isn't part of a phrase, so chats start empty. The decoy profile gets a new phrase of its own.")
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

/// Which profiles a restore brings back.
enum RestoreTarget: Hashable {
    /// The real profile (PIN 1); the decoy starts new.
    case real
    /// The decoy profile (PIN 2); the real one starts new.
    case decoy
    /// Both, each from its own 24 words.
    case both
}

/// Restore: pick which profile comes back (the real one, the decoy, or both with a phrase each;
/// a profile that isn't restored starts new), enter the 24-word recovery phrase and roughly
/// where the wallets started (a block height, a date, or neither; see `WalletStart`). Starting
/// with new profiles is the way Zignal is meant to start, so this screen says so in red.
struct RestorePhraseView: View {
    /// The picked profile's phrase; with `.both`, the real profile's (PIN 1).
    @State private var phrase = ""
    /// With `.both`: the decoy profile's phrase (PIN 2).
    @State private var decoyPhrase = ""
    @State private var heightText = ""
    @State private var target = RestoreTarget.real
    /// Nil until a date is picked: never today, since a wallet restored with today's date
    /// wouldn't find the funds it received before.
    @State private var created: Date?
    @State private var restored: RestoredProfile?
    @State private var errorText: String?
    /// Starts true: the fields stay hidden until the watcher has reported the capture state.
    @State private var screenCaptured = true
    @State private var screenshotTaken = false

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var phrasesComplete: Bool {
        Self.wordCount(phrase) == 24 && (target != .both || Self.wordCount(decoyPhrase) == 24)
    }

    var body: some View {
        let height = WalletStart.check(heightText)
        Form {
            Section {
                Text("Restoring isn't advised. Zignal is meant to start with new profiles: go back and tap Get started. Restore only a Zignal messenger profile you made before. If these words are also in another app, the panic PIN can't erase that copy.")
                    .foregroundStyle(.red)
            }
            Section {
                Picker("Profile", selection: $target) {
                    Text("PIN 1 profile").tag(RestoreTarget.real)
                    Text("PIN 2 profile").tag(RestoreTarget.decoy)
                    Text("Both").tag(RestoreTarget.both)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Which messenger profile are you restoring?")
            } footer: {
                Text(target == .both
                     ? "Both profiles come back, each from its own 24 words: PIN 1 (the unlock PIN) opens your real profile, PIN 2 (the duress PIN) the decoy. Chats don't come back. Don't swap the two phrases: the PIN 2 profile is the one you show under pressure, and the panic PIN erases the PIN 1 profile."
                     : "The phrase brings back that one profile: PIN 1 (the unlock PIN) opens your real profile, PIN 2 (the duress PIN) the decoy. The other profile starts new. Chats don't come back. Pick PIN 2 only for a phrase that was your decoy: that profile is the one you show under pressure, and the panic PIN doesn't erase it.")
            }
            phraseSection(target == .both ? "PIN 1 profile's recovery phrase" : "Recovery phrase",
                          text: $phrase)
            if target == .both {
                phraseSection("PIN 2 profile's recovery phrase", text: $decoyPhrase)
            }
            Section {
                WalletStartFields(heightText: $heightText, date: $created)
            } header: {
                Text(target == .both ? "When were these profiles created?" : "When was this profile created?")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if target == .both {
                        Text("One start is used for both profiles. If they were made on different days, enter the earlier one.")
                    }
                    WalletStartFooter(height: height)
                }
            }
            Section {
                Button("Continue", action: check)
                    .disabled(!phrasesComplete || !height.isUsable)
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Restore")
        .scrollDismissesKeyboard(.interactively)
        .background(ScreenCaptureWatcher(isCaptured: $screenCaptured))
        .onScreenshot {
            if !screenCaptured && !(phrase.isEmpty && decoyPhrase.isEmpty) { screenshotTaken = true }
        }
        .onChange(of: target) { _, picked in
            // The second phrase isn't kept once it's no longer asked for.
            if picked != .both { decoyPhrase = "" }
            errorText = nil
        }
        .navigationDestination(item: $restored) { restore in
            PinSetupView(restore: restore)
        }
    }

    /// One recovery phrase field, hidden while the screen is recorded, mirrored or shared.
    private func phraseSection(_ title: String, text: Binding<String>) -> some View {
        Section {
            if screenCaptured {
                CapturedScreenNotice()
            } else {
                TextField("24 words, separated by spaces", text: text, axis: .vertical)
                    .lineLimit(4...8)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Self.wordCount(text.wrappedValue)) of 24 words")
                if screenshotTaken {
                    ScreenshotWarning()
                }
            }
        }
    }

    private func check() {
        errorText = nil
        let height = WalletStart.check(heightText).value
        let invalid = ZignalError.invalidRecoveryPhrase.errorDescription
            ?? "That isn't a valid 24-word recovery phrase."
        guard let first = try? profileSecretFromPhrase(phrase: phrase) else {
            errorText = target == .both ? "PIN 1 profile: " + invalid : invalid
            return
        }
        switch target {
        case .real:
            restored = RestoredProfile(realSecret: first, decoySecret: nil,
                                       created: created, height: height)
        case .decoy:
            restored = RestoredProfile(realSecret: nil, decoySecret: first,
                                       created: created, height: height)
        case .both:
            guard let second = try? profileSecretFromPhrase(phrase: decoyPhrase) else {
                errorText = "PIN 2 profile: " + invalid
                return
            }
            guard first != second else {
                errorText = "Both phrases are the same. Each profile has its own 24 words."
                return
            }
            restored = RestoredProfile(realSecret: first, decoySecret: second,
                                       created: created, height: height)
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
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let wait = model.remainingWait()
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

/// Where a restored wallet starts looking for its funds: a block height, or a date picked on a
/// wheel, or both (the earlier one is used). Used on the restore screen and when a profile's
/// file wasn't on the phone.
struct WalletStartFields: View {
    @Binding var heightText: String
    @Binding var date: Date?
    @State private var pickingDate = false
    @State private var wheelDate = WalletDates.zignalFirst

    var body: some View {
        TextField("Restore from block height",
                  text: $heightText,
                  prompt: Text("Restore from block height, e.g. \(WalletStart.exampleHeight.formatted())"))
            .keyboardType(.numberPad)
            .autocorrectionDisabled()
        Text("or").foregroundStyle(.secondary)
        Button {
            wheelDate = date ?? WalletDates.zignalFirst
            pickingDate = true
        } label: {
            HStack {
                Text("Restore from date").foregroundStyle(.primary)
                Spacer()
                Text(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not picked")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $pickingDate) {
            NavigationStack {
                // The range never ends before the default date, also on a phone whose clock is
                // far behind (a range that ends before it starts would stop the app).
                DatePicker("Restore from date", selection: $wheelDate,
                           in: WalletDates.earliest...max(Date(), WalletDates.zignalFirst),
                           displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding()
                    .navigationTitle("Restore from date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { pickingDate = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                date = wheelDate
                                pickingDate = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }
}

/// The explanation under `WalletStartFields`, with a red line when the height can't be used.
struct WalletStartFooter: View {
    let height: WalletStart.HeightCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter a date a few days before you created this profile, or its block height if you know it. With both, the earlier one is used; with neither, October 1, 2026. Earlier is safe but makes the first sync slower.")
            Text("On this phone the profile starts fresh and looks for its funds only from that point. Anything received before it won't show.")
                .foregroundStyle(.red)
            if let message = height.message {
                Text(message).foregroundStyle(.red)
            }
        }
    }
}
