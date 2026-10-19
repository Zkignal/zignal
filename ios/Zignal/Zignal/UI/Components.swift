import SwiftUI

/// Shown over everything while the app is not active.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Numeric PIN entry: digits only, length-capped, no autocorrect or capitalization,
    /// and redacted wherever iOS treats content as privacy-sensitive.
    func pinInput(_ text: Binding<String>) -> some View {
        modifier(PinInput(text: text))
    }
}

private struct PinInput: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .keyboardType(.numberPad)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .privacySensitive()
            .onChange(of: text) { _, newValue in
                let digits = String(newValue.filter { "0123456789".contains($0) }
                    .prefix(PinPolicy.maxLength))
                if digits != newValue { text = digits }
            }
    }
}

extension View {
    /// Keeps PIN entry predictable when the app loses and regains focus. The privacy cover
    /// dismisses the keyboard whenever Zignal isn't active (app switcher, Control Center, a
    /// system alert), and iOS silently clears a secure field on the first key typed after that.
    /// So the field is emptied when the app goes inactive and focused again when it returns:
    /// every entry starts clean instead of quietly losing digits.
    func resetsPinEntry(_ pin: Binding<String>, focused: FocusState<Bool>.Binding) -> some View {
        modifier(PinEntryReset(pin: pin, focused: focused))
    }
}

private struct PinEntryReset: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var pin: String
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active {
                focused.wrappedValue = true
            } else {
                pin = ""
                focused.wrappedValue = false
            }
        }
    }
}

/// The line under a PIN field: the wrong-PIN countdown, "Checking PIN…", or the last error.
struct PinStatus: View {
    let wait: TimeInterval
    let checking: Bool
    let error: String?

    var body: some View {
        Group {
            if wait > 0 {
                Text(AppModel.waitMessage(wait)).foregroundStyle(.red).monospacedDigit()
            } else if checking {
                Text("Checking PIN…").foregroundStyle(.secondary)
            } else {
                Text(error ?? " ").foregroundStyle(.red)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
    }
}

/// A 60-digit safety number as 12 groups of 5, read left to right.
struct SafetyNumberGrid: View {
    let number: String

    private var groups: [String] {
        let digits = Array(number.filter(\.isNumber))
        return stride(from: 0, to: digits.count, by: 5).map {
            String(digits[$0..<min($0 + 5, digits.count)])
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { item in
                Text(item.element).font(.body.monospaced())
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
