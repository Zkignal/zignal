import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Vision
import VisionKit

/// Shows a new invite as a QR code for one contact to scan.
struct ShowInviteView: View {
    private let session: ProfileSession
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var errorText: String?
    @State private var copied = false

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let code {
                        // Low error correction keeps this large code as sparse as possible;
                        // a screen held up to a camera doesn't need more.
                        QRCodeView(text: code, correction: "L")
                            .padding(12)
                            .background(.white, in: .rect(cornerRadius: 16))
                        Text("On your contact's phone: New chat, then Scan or paste an invite.")
                            .multilineTextAlignment(.center)
                        Button(copied ? "Copied" : "Copy invite", systemImage: "doc.on.doc") {
                            Clipboard.copy(code)
                            copied = true
                        }
                    } else if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else {
                        ProgressView("Creating invite")
                    }
                    Text("Works once: the first person to use it becomes your contact. It holds a new address used only for that contact, and your public keys. Showing it in person is safest; after your first messages, compare safety numbers to mark the contact verified.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Your invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                guard code == nil else { return }
                do {
                    code = try await session.makeInvite()
                } catch {
                    errorText = AppModel.describe(error)
                }
            }
        }
    }
}

/// Starts a chat from a contact's invite: scan or paste it, then write a first message.
struct AcceptInviteView: View {
    private let session: ProfileSession
    private let onStarted: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var firstText = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var cameraReady = false

    /// - Parameter onStarted: called with the new contact once the chat has started.
    init(session: ProfileSession, onStarted: @escaping (Data) -> Void) {
        self.session = session
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                if code == nil {
                    Section {
                        if cameraReady {
                            InviteScanner { accept($0) }
                                .frame(height: 320)
                                .listRowInsets(EdgeInsets())
                        }
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { accept(text) }
                        }
                    } footer: {
                        Text(cameraReady
                             ? "Point the camera at your contact's invite, or paste one they sent you."
                             : "Paste the invite your contact sent you. To scan instead, allow camera access for Zignal in Settings (needs iPhone XS or later).")
                    }
                } else {
                    Section {
                        Label("Invite found", systemImage: "checkmark.circle")
                        TextField("First message", text: $firstText, axis: .vertical)
                            .autocorrectionDisabled()
                            .lineLimit(1...6)
                    } footer: {
                        Text("Your first message starts the encrypted chat. It goes out as one shielded transaction; the network fee is about 0.0002 ZEC.")
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if code != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if sending {
                            ProgressView()
                        } else {
                            Button("Send", action: send).disabled(!canSend)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(sending)
            .task {
                // Asks for the camera the first time; returns at once after that.
                guard InviteScanner.isSupported else { return }
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraReady = InviteScanner.isAvailable
            }
        }
    }

    private var canSend: Bool {
        let text = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf8.count <= ProfileSession.maxTextBytes
            && session.wallet?.canTransact == true
    }

    /// Takes the first scanned or pasted text that is a valid invite.
    private func accept(_ text: String) {
        guard code == nil else { return }
        guard let invite = InviteCode.decode(text), InviteCode.inviterID(invite) != nil else {
            errorText = ZignalError.invalidInvite.errorDescription
            return
        }
        guard let address = InviteCode.address(invite), PaymentRequest.isShieldedAddress(address) else {
            errorText = ZignalError.invalidAddress.errorDescription
            return
        }
        code = text
        errorText = nil
    }

    private func send() {
        guard let code, !sending else { return }
        sending = true
        errorText = nil
        Task {
            let peer = await session.acceptInvite(code, firstText: firstText)
            sending = false
            if let peer {
                // A failed broadcast still starts the chat: the message shows as not sent,
                // with tap to send again, and the error appears on the chat screen.
                dismiss()
                onStarted(peer)
            } else {
                // Shown here, not as an alert behind this sheet.
                errorText = session.errorText ?? ZignalError.invalidInvite.errorDescription
                session.errorText = nil
            }
        }
    }
}

/// The live camera QR scanner. Calls `onCode` with each new QR code it reads.
struct InviteScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    /// False on devices without the scanner (before iPhone XS).
    static var isSupported: Bool { DataScannerViewController.isSupported }

    /// False without camera access, or on devices without the scanner.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    onCode(text)
                    return
                }
            }
        }
    }
}

/// Copies to this phone only: never to other devices through Universal Clipboard, and
/// cleared after five minutes.
enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
        )
    }
}
