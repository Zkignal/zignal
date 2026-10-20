import CoreImage.CIFilterBuiltins
import SwiftUI

/// The wallet at the top of the chat list: sync state, balance, funding and settings.
struct WalletSection: View {
    private let session: ProfileSession
    @State private var showFunds = false
    @State private var showSettings = false
    @State private var preparing = false
    @State private var prepared = false

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        if let wallet = session.wallet {
            Section {
                HStack {
                    Label(statusText(wallet.phase), systemImage: statusIcon(wallet.phase))
                        .foregroundStyle(isFailed(wallet.phase) ? Color.red : Color.primary)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(ZecFormat.string(wallet.spendable)).monospacedDigit()
                        if wallet.pending > 0 {
                            Text("+ \(ZecFormat.string(wallet.pending)) confirming")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                HStack(spacing: 20) {
                    Button("Add funds", systemImage: "qrcode") { showFunds = true }
                    Button(prepared ? "Prepared" : "Prepare for chatting", systemImage: "square.split.2x2") {
                        Task {
                            preparing = true
                            prepared = await session.prepareForChatting()
                            preparing = false
                        }
                    }
                    .disabled(preparing || prepared || !wallet.canTransact || wallet.spendable <= 0)
                    Spacer()
                    Button("Network", systemImage: "network") { showSettings = true }
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                // On this row, not the section: a modifier on a section applies to every row.
                .sheet(isPresented: $showFunds) { AddFundsView(session: session) }
                .sheet(isPresented: $showSettings) { WalletSettingsView(session: session) }
            } header: {
                Text("Wallet")
            } footer: {
                Text("Each message is one shielded Zcash transaction and costs about 0.0001 ZEC in network fees. \"Prepare for chatting\" splits your balance so several messages can go out in a row.")
            }
        }
    }

    private func statusText(_ phase: WalletEngine.Phase) -> String {
        switch phase {
        case .starting: "Starting"
        case .syncing(let percent): "Syncing \(percent)%"
        case .ready: "Up to date"
        case .stopped: "Stopped"
        case .failed(let reason): reason
        }
    }

    private func statusIcon(_ phase: WalletEngine.Phase) -> String {
        switch phase {
        case .starting, .syncing: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func isFailed(_ phase: WalletEngine.Phase) -> Bool {
        if case .failed = phase { true } else { false }
    }
}

/// A fresh shielded address to fund this profile's wallet.
struct AddFundsView: View {
    private let session: ProfileSession
    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var errorText: String?
    @State private var copied = false

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let address {
                        QRCodeView(text: address)
                            .frame(maxWidth: 280)
                            .padding()
                            .background(.white, in: .rect(cornerRadius: 16))
                        Text(address)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        Button(copied ? "Copied" : "Copy address", systemImage: "doc.on.doc") {
                            Clipboard.copy(address)
                            copied = true
                        }
                    } else if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                    Text("Send ZEC from any wallet that supports shielded (Orchard) addresses. It can be spent after 10 confirmations: about 12 minutes today, about 4 after NU7. Start small: a few hundred messages cost about 0.03 ZEC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Add funds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                guard address == nil else { return }
                do {
                    guard let wallet = session.wallet else { throw ZignalError.walletNotReady }
                    address = try await wallet.newAddress()
                } catch {
                    errorText = AppModel.describe(error)
                }
            }
        }
    }
}

/// Server and Tor choices for this profile's wallet.
struct WalletSettingsView: View {
    private let session: ProfileSession
    @Environment(\.dismiss) private var dismiss
    @State private var servers: [WalletSettings.Server] = []
    @State private var torEnabled = true
    @State private var newServer = ""

    init(session: ProfileSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use Tor", isOn: $torEnabled)
                } footer: {
                    Text("Off by default. The server you use can see your IP address. With Tor on, it can't for sending and fetching messages, but downloading blocks still connects directly, and the wallet starts more slowly. Your own server hides it completely.")
                }
                Section {
                    ForEach(servers, id: \.self) { server in
                        Text(server.label).font(.body.monospaced())
                    }
                    .onDelete { servers.remove(atOffsets: $0) }
                    .onMove { servers.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("host:port", text: $newServer)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button("Add") {
                            if let server = WalletSettings.Server(newServer), !servers.contains(server) {
                                servers.append(server)
                                newServer = ""
                            }
                        }
                        .disabled(WalletSettings.Server(newServer) == nil)
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("The first server is used; drag to reorder. These are public lightwalletd servers, not run by Zignal. Add your own to stop relying on them.")
                }
                Section {
                    Button("Restore defaults") {
                        servers = WalletSettings.standard.servers
                        torEnabled = WalletSettings.standard.torEnabled
                    }
                }
            }
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let settings = WalletSettings(servers: servers, torEnabled: torEnabled)
                        Task { await session.updateWalletSettings(settings) }
                        dismiss()
                    }
                    .disabled(servers.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .onAppear {
                servers = session.walletSettings.servers
                torEnabled = session.walletSettings.torEnabled
            }
        }
    }
}

/// A QR code for text, drawn sharp at any size. Generated once per text, not on every redraw.
struct QRCodeView: View {
    private let text: String
    private let correction: String
    @State private var image: UIImage?
    @State private var failed = false

    /// - Parameter correction: error correction, "L", "M", "Q" or "H". Lower fits more data
    ///   in fewer, larger squares.
    init(text: String, correction: String = "M") {
        self.text = text
        self.correction = correction
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("QR code")
            } else if failed {
                Text("Couldn't draw the QR code. Use Copy instead.").foregroundStyle(.secondary)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: text) {
            image = Self.image(for: text, correction: correction)
            failed = image == nil
        }
    }

    private static func image(for text: String, correction: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
