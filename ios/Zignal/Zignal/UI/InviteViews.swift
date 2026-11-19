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
                        Text("Only one of you scans. If you both scan each other's invite, the chat won't work.")
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Button(copied ? "Copied" : "Copy invite", systemImage: "doc.on.doc") {
                            Clipboard.copy(code)
                            copied = true
                        }
                        Button("Share invite", systemImage: "square.and.arrow.up") {
                            ShareSheet.present(code)
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
    @State private var pasted = ""
    /// The contact's name when the invite comes from someone already in the contacts.
    @State private var replacing: String?
    @State private var confirmReplace = false

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
                        // Paste comes first: it works without camera access.
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { accept(text) }
                        }
                        // Also takes a long-press Paste, in case the button above has nothing
                        // to offer for an invite copied from another app.
                        TextField("Or paste the invite here", text: $pasted, axis: .vertical)
                            .lineLimit(1...3)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: pasted) { _, text in
                                // An invite arrives all at once when pasted; don't judge typing.
                                if text.count >= 40 { accept(text) }
                            }
                        if cameraReady {
                            InviteScanner { accept($0) }
                                .frame(height: 320)
                                .listRowInsets(EdgeInsets())
                        }
                    } footer: {
                        Text(scanFooter)
                    }
                } else {
                    Section {
                        if let replacing {
                            Label("New invite from \(replacing)", systemImage: "exclamationmark.triangle")
                        } else {
                            Label("Invite found", systemImage: "checkmark.circle")
                        }
                        TextField("First message", text: $firstText, axis: .vertical)
                            .autocorrectionDisabled()
                            .lineLimit(1...6)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            if let replacing {
                                Text("You already have a chat with \(replacing). Sending starts it over: messages sent on the old chat after that may not arrive. Do this only if \(replacing) made this invite just now, for example after restoring their phone.")
                            }
                            Text(session.wallet?.canTransact == true
                                 ? "Your first message starts the encrypted chat. It goes out as one shielded transaction; the network fee is about 0.00025 ZEC."
                                 : "Send becomes available once the wallet has started.")
                        }
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
                            Button(replacing == nil ? "Send" : "Start over") {
                                if replacing == nil { send() } else { confirmReplace = true }
                            }
                            .disabled(!canSend)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(sending)
            .confirmationDialog("Start the chat with \(replacing ?? "this contact") over?",
                                isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Start over", role: .destructive, action: send)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only if they made this invite just now. If it's the invite you scanned before, cancel: an invite works only once.")
            }
            .task {
                // Asks for the camera the first time; returns at once after that.
                guard InviteScanner.isSupported else { return }
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraReady = InviteScanner.isAvailable
            }
        }
    }

    private var scanFooter: String {
        (cameraReady
         ? "Paste the invite your contact sent you, or point the camera at their invite."
         : "Paste the invite your contact sent you. To scan instead, allow camera access for Zignal in Settings (needs iPhone XS or later).")
            + " Only one of you scans: if your contact has scanned your invite, don't scan theirs."
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
        do {
            switch try session.checkInvite(invite) {
            case .new:
                replacing = nil
            case .existingContact(let name):
                replacing = name
            case .ownInvite:
                errorText = ZignalError.ownInvite.errorDescription
                return
            case .alreadyUsed:
                errorText = ZignalError.inviteAlreadyUsed.errorDescription
                return
            }
        } catch {
            errorText = AppModel.describe(error)
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
            let peer = await session.acceptInvite(code, firstText: firstText, replacing: replacing != nil)
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

/// Copies to this phone only: never to other devices through Universal Clipboard. The copy
/// expires after 60 seconds: iOS removes it then, whatever else happens. The Lock button removes
/// it sooner (see `clearOurCopy`). The next unlock tries to as well, also after the app was
/// ended, but an iPhone test (November 19) showed it can miss after a trip to the Home Screen;
/// the cause isn't known yet, so the expiry is the limit to rely on. Going to the background
/// keeps the copy, so it can be pasted into another app. Stored as UTF-8 plain text, the type
/// that the system Paste button and other apps read as text.
@MainActor
enum Clipboard {
    /// How long a copy stays on the pasteboard when nothing removes it sooner.
    static let lifetime: TimeInterval = 60
    /// Where the mark is kept. Tests use their own service.
    static var markService = Keychain.appService
    /// The pasteboard's change count right after Zignal's last copy. While it's unchanged, what's
    /// on the pasteboard is still Zignal's copy. Also kept in the Keychain (`pasteboardMark`),
    /// because this is gone once the app is ended.
    private static var ourCopy: Int?

    static func copy(_ text: String) {
        let expires = Date().addingTimeInterval(lifetime)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: expires]
        )
        let count = UIPasteboard.general.changeCount
        ourCopy = count
        // Only the count and the expiry time, never what was copied.
        let mark = "\(count) \(Int(expires.timeIntervalSince1970))"
        try? Keychain.write(Data(mark.utf8), to: .pasteboardMark, service: markService)
    }

    /// Removes Zignal's copy if it's still on the pasteboard, so a message, an invite or an
    /// address copied in one profile can't be pasted after a lock (into the other profile, or
    /// into another app). Something copied since, in Zignal or elsewhere, is left alone.
    static func clearOurCopy() {
        let count = ourCopy ?? savedMark()
        ourCopy = nil
        try? Keychain.delete(.pasteboardMark, service: markService)
        guard let count, UIPasteboard.general.changeCount == count else { return }
        UIPasteboard.general.items = []
    }

    /// The change count kept by an earlier run of the app. Nil once the copy has expired: iOS
    /// removed it then, and a later copy elsewhere may have the same count after a restart.
    private static func savedMark() -> Int? {
        guard let data = try? Keychain.read(.pasteboardMark, service: markService) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: " ")
        guard parts.count == 2, let count = Int(parts[0]), let expires = Int(parts[1]),
              Date().timeIntervalSince1970 < TimeInterval(expires) else { return nil }
        return count
    }

    /// Tests only: forgets the in-memory mark, as ending the app does.
    static func forgetInMemoryMark() {
        ourCopy = nil
    }
}

/// The system share sheet for an invite or an address, so it goes straight to the app the user
/// picks (Messages, Signal, AirDrop) without passing through the pasteboard. Its own Copy action
/// is left out: that would put the text on the general pasteboard, with no expiry.
@MainActor
enum ShareSheet {
    static let excluded: [UIActivity.ActivityType] = [
        .copyToPasteboard, .addToReadingList, .assignToContact, .print, .saveToCameraRoll,
    ]

    static func present(_ text: String) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.excludedActivityTypes = excluded
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}
