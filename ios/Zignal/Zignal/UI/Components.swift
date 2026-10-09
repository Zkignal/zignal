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
