import Combine
import Foundation
// The SDK predates Swift concurrency checking; every call into it is made on the main actor.
@preconcurrency import ZcashLightClientKit

/// The Zcash wallet of the unlocked profile, on mainnet.
///
/// Started after unlock and stopped on lock. Each profile has its own wallet (its own seed,
/// files and settings), so the duress PIN opens a separate wallet that works like a real one.
/// This is the only type that talks to the Zcash SDK; everything it hands back is plain data.
@MainActor
@Observable
final class WalletEngine {
    enum Phase: Equatable {
        case starting
        case syncing(Int) // percent
        case ready
        case stopped
        case failed(String)
    }

    /// What the wallet holds, as of its latest sync.
    struct Snapshot {
        /// Transactions from others, oldest first, with their block time (unix seconds) and
        /// the 512-byte memos they carry for us.
        var incoming: [(txid: Data, time: UInt64, memos: [Data])] = []
        /// Transactions that are in a block.
        var mined: Set<Data> = []
        /// Our transactions that expired without being mined.
        var expired: Set<Data> = []
        /// The wallet had scanned every block when this was read. Before that, newer blocks
        /// can be scanned before older ones, so a reply can show up before the message that
        /// started its chat.
        var complete = false
    }

    private(set) var phase: Phase = .starting
    /// Zatoshis that can be spent now.
    private(set) var spendable: Int64 = 0
    /// Zatoshis received or returned as change that aren't spendable yet.
    private(set) var pending: Int64 = 0
    private(set) var settings: WalletSettings

    /// Prepared and able to build transactions (also while it keeps syncing).
    var canTransact: Bool {
        guard account != nil else { return false }
        switch phase {
        case .stopped, .failed: return false
        default: return true
        }
    }

    /// Called whenever new or newly mined transactions may be readable.
    @ObservationIgnored var onChange: (@MainActor () async -> Void)?

    @ObservationIgnored private let seed: [UInt8]
    @ObservationIgnored private let alias: String
    @ObservationIgnored private let restoreFrom: Date?
    @ObservationIgnored private var synchronizer: SDKSynchronizer?
    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private let networkType: NetworkType = .mainnet

    /// - Parameters:
    ///   - seed: the profile's 64-byte BIP-39 wallet seed.
    ///   - alias: names this profile's wallet files; derived from the profile key.
    ///   - restoreFrom: for a profile restored from its phrase, about when the wallet was
    ///     created. Nil for a new wallet, which starts at the current chain height.
    init(seed: Data, alias: String, settings: WalletSettings, restoreFrom: Date?) {
        self.seed = [UInt8](seed)
        self.alias = alias
        self.settings = settings
        self.restoreFrom = restoreFrom
    }

    // MARK: - Lifecycle

    func start() async {
        guard synchronizer == nil else { return }
        phase = .starting
        do {
            let files = try WalletFiles(alias: alias)
            let initializer = Initializer(
                cacheDbURL: nil,
                fsBlockDbRoot: files.fsBlockDbRoot,
                generalStorageURL: files.generalStorage,
                dataDbURL: files.dataDb,
                torDirURL: files.torDir,
                endpoint: Self.endpoint(settings.servers.first ?? WalletSettings.defaultServers[0]),
                network: ZcashNetworkBuilder.network(for: networkType),
                spendParamsURL: files.spendParams,
                outputParamsURL: files.outputParams,
                saplingParamsSourceURL: .default,
                alias: .custom(alias),
                loggingPolicy: .noLogging,
                isTorEnabled: settings.torEnabled,
                isExchangeRateEnabled: false
            )
            let sync = SDKSynchronizer(initializer: initializer)
            synchronizer = sync
            let birthday = restoreFrom.map { sync.estimateBirthdayHeight(for: $0) }
            let result = try await sync.prepare(with: seed, walletBirthday: birthday, name: "Zignal", keySource: nil)
            guard synchronizer === sync else { return } // locked while preparing
            guard result == .success, let first = try await sync.listAccounts().first else {
                throw ZignalError.walletMismatch
            }
            guard synchronizer === sync else { return }
            account = first
            files.protectContents()
            observe(sync)
            try await sync.start(retry: true)
        } catch {
            guard synchronizer != nil else { return }
            phase = .failed(AppModel.describe(error))
        }
    }

    /// Stops syncing and drops the wallet. Called on lock.
    func stop() {
        subscriptions.removeAll()
        synchronizer?.stop()
        synchronizer = nil
        account = nil
        phase = .stopped
    }

    /// Applies new server or Tor settings to the running wallet.
    func apply(_ newSettings: WalletSettings) async {
        let old = settings
        settings = newSettings
        guard let sync = synchronizer else { return }
        do {
            if newSettings.torEnabled != old.torEnabled {
                try await sync.tor(enabled: newSettings.torEnabled)
            }
            if let server = newSettings.servers.first, server != old.servers.first {
                try await sync.switchTo(endpoint: Self.endpoint(server))
            }
        } catch {
            phase = .failed(AppModel.describe(error))
        }
    }

    // MARK: - Reading

    /// Reads the wallet's transactions. Transactions in `processed` are skipped, and so is any
    /// transaction whose memos the wallet hasn't fetched yet (it comes back on a later call).
    func snapshot(skipping processed: Set<Data>) async throws -> Snapshot {
        guard let sync = synchronizer, let account else { return Snapshot() }
        var snapshot = Snapshot()
        snapshot.complete = phase == .ready
        // The SDK lists newest first. Messages are read oldest first, as they were sent.
        let transactions = try await sync.allTransactions()
            .filter { $0.accountUUID == account.id }
            .sorted { ($0.minedHeight ?? .max, $0.index ?? 0) < ($1.minedHeight ?? .max, $1.index ?? 0) }
        for tx in transactions {
            if tx.minedHeight != nil { snapshot.mined.insert(tx.rawID) }
            if tx.state == .expired || tx.isExpiredUmined == true { snapshot.expired.insert(tx.rawID) }
            guard !tx.isSentTransaction, !processed.contains(tx.rawID) else { continue }
            let outputs = await sync.getTransactionOutputs(for: tx).map(Self.reduce)
            guard let memos = IncomingMemos.extract(from: outputs) else { continue }
            let time = UInt64(max(0, tx.blockTime ?? Date().timeIntervalSince1970))
            snapshot.incoming.append((tx.rawID, time, memos))
        }
        return snapshot
    }

    /// A new shielded-only (Orchard) address. Each contact and each invite gets its own, so
    /// contacts can't link you across chats.
    func newAddress() async throws -> String {
        guard let sync = synchronizer, let account else { throw ZignalError.walletNotReady }
        return try await sync.getCustomUnifiedAddress(accountUUID: account.id, receivers: [.orchard]).stringEncoded
    }

    // MARK: - Sending

    /// Sends the memos as one shielded transaction to `address`: one zero-value output per
    /// memo. Returns the transaction id.
    func send(memos: [Data], to address: String) async throws -> Data {
        guard PaymentRequest.isShieldedAddress(address) else { throw ZignalError.invalidAddress }
        guard (1...15).contains(memos.count), memos.allSatisfy({ $0.count == 512 }) else {
            throw ZignalError.messageTooLong
        }
        return try await submit(PaymentRequest.memos(memos, to: address))
    }

    /// Splits the spendable balance into `count` notes by paying ourselves, so several
    /// messages can go out back to back. Each send locks its note until the change has 3
    /// confirmations; with one note, that's one message every few minutes.
    func prepareForChatting(notes count: Int = 10) async throws -> Data {
        // ZIP-317: 5,000 zatoshis per action; one spend and `count` outputs (the last is change).
        let fee = Int64(5_000 * max(2, count))
        let each = (spendable - fee) / Int64(count)
        guard count >= 2, each >= 20_000 else { throw ZignalError.notEnoughFunds }
        let address = try await newAddress()
        return try await submit(PaymentRequest.payments(Array(repeating: each, count: count - 1), to: address))
    }

    private func submit(_ uri: String) async throws -> Data {
        guard let sync = synchronizer, let account else { throw ZignalError.walletNotReady }
        let proposal: Proposal
        do {
            proposal = try await sync.proposefulfillingPaymentURI(uri, accountUUID: account.id)
        } catch ZcashError.rustProposeTransferFromURI(let reason)
                    where reason.localizedCaseInsensitiveContains("insufficient") {
            throw ZignalError.notEnoughFunds
        }
        let key = try DerivationTool(networkType: networkType)
            .deriveUnifiedSpendingKey(seed: seed, accountIndex: account.hdAccountIndex ?? Zip32AccountIndex(0))
        var sent: Data?
        for try await result in try await sync.createProposedTransactions(proposal: proposal, spendingKey: key) {
            switch result {
            case .success(let txid):
                sent = txid
            case .grpcFailure(_, let error):
                throw error
            case .submitFailure(_, _, let description):
                throw ZignalError.sendRejected(description)
            case .notAttempted:
                throw ZignalError.sendRejected("The transaction was not sent.")
            }
        }
        guard let sent else { throw ZignalError.sendRejected("No transaction was created.") }
        return sent
    }

    // MARK: - Updates from the SDK

    private func observe(_ sync: SDKSynchronizer) {
        sync.stateStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in MainActor.assumeIsolated { self?.apply(state) } }
            .store(in: &subscriptions)
        sync.eventStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
            .store(in: &subscriptions)
    }

    private func apply(_ state: SynchronizerState) {
        let wasReady = phase == .ready
        switch state.syncStatus {
        case .unprepared:
            phase = .starting
        case let .syncing(progress, _):
            phase = .syncing(Int((progress * 100).rounded()))
        case .upToDate:
            phase = .ready
        case .stopped:
            phase = .stopped
        case let .error(error):
            phase = .failed(AppModel.describe(error))
        }
        if let id = account?.id, let balance = state.accountsBalances[id] {
            let pools = [balance.saplingBalance, balance.orchardBalance, balance.ironwoodBalance]
            spendable = pools.reduce(0) { $0 + $1.spendableValue.amount }
            pending = pools.reduce(0) {
                $0 + $1.changePendingConfirmation.amount + $1.valuePendingSpendability.amount
            }
        }
        if phase == .ready && !wasReady { changed() }
    }

    private func handle(_ event: SynchronizerEvent) {
        switch event {
        case .foundTransactions, .minedTransaction:
            changed()
        default:
            break
        }
    }

    private func changed() {
        guard let onChange else { return }
        Task { await onChange() }
    }

    // MARK: - Helpers

    private static func endpoint(_ server: WalletSettings.Server) -> LightWalletEndpoint {
        LightWalletEndpoint(address: server.host, port: server.port, secure: true)
    }

    private static func reduce(_ output: ZcashTransaction.Output) -> WalletOutput {
        let memo: WalletOutput.Memo
        switch output.memo {
        case .arbitrary(let bytes)?: memo = .binary(bytes)
        case nil: memo = .notFetched
        default: memo = .other
        }
        return WalletOutput(fromUs: output.fromAccount != nil, isChange: output.isChange,
                            isShielded: output.pool != .transaparent, memo: memo)
    }
}

/// Where one profile's wallet keeps its files. Both profiles share one folder, and the SDK
/// prefixes every file with the profile's alias ("c_<alias>_data.db" and so on). The alias is
/// derived from that profile's key and says nothing about which profile is which.
struct WalletFiles {
    let root: URL
    let alias: String

    static var standardRoot: URL {
        URL.applicationSupportDirectory.appending(path: "zkw-wallet", directoryHint: .isDirectory)
    }

    /// Creates the folder with complete data protection, excluded from device backups.
    init(alias: String, root: URL = WalletFiles.standardRoot) throws {
        self.alias = alias
        self.root = root
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try linkSaplingParams()
    }

    var fsBlockDbRoot: URL { root.appending(path: ZcashSDK.defaultFsCacheName, directoryHint: .isDirectory) }
    var generalStorage: URL { root.appending(path: "general", directoryHint: .isDirectory) }
    var dataDb: URL { root.appending(path: ZcashSDK.defaultDataDbName, directoryHint: .notDirectory) }
    var torDir: URL { root.appending(path: ZcashSDK.defaultTorDirName, directoryHint: .isDirectory) }
    var spendParams: URL { root.appending(path: ZcashSDK.spendParamFilename, directoryHint: .notDirectory) }
    var outputParams: URL { root.appending(path: ZcashSDK.outputParamFilename, directoryHint: .notDirectory) }

    /// The SDK refuses to build any transaction without the Sapling parameters, and reads them
    /// from "c_<alias>_sapling-*.params". When the app ships them (scripts/fetch-sapling-params.sh
    /// puts them in Zignal/SaplingParams), those names link to the copies inside the app, so
    /// both profiles share one copy and nothing is downloaded. Relinked on every start because
    /// the app's path changes with each install or update. Without them in the app, the SDK
    /// downloads them on the first send (not over Tor).
    private func linkSaplingParams() throws {
        for name in [ZcashSDK.spendParamFilename, ZcashSDK.outputParamFilename] {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let bundled = Bundle.main.url(forResource: base, withExtension: ext)
                    ?? Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "SaplingParams")
            else { continue }
            let link = root.appending(path: "c_\(alias)_\(name)", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)
        }
    }

    /// Deletes every wallet file except those of the profile with `keepAlias`. Called after a
    /// silent wipe: the wiped profile's wallet database (addresses, transactions, memos) would
    /// otherwise stay on the phone. Its alias can't be known any more, but everything that isn't
    /// the open profile's is the wiped profile's. Deleting a file on iOS also destroys its
    /// per-file encryption key.
    static func removeWallets(except keepAlias: String, root: URL = WalletFiles.standardRoot) {
        let keep = "c_\(keepAlias)_"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where !name.hasPrefix(keep) {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    /// Complete data protection on everything the SDK has created so far. New files inherit
    /// it from the folder; this covers files made before that setting existed. Links to the
    /// parameters inside the app are skipped: the app's own files are read-only.
    func protectContents() {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return
        }
        for case let url as URL in items {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                   ofItemAtPath: url.path)
        }
    }
}
