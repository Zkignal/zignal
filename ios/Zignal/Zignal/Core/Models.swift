import Foundation

/// Everything one profile keeps on disk. Stored only inside its encrypted profile file.
struct ProfileData: Codable, Equatable {
    var version = 1
    /// zkw-core inbox state, already sealed by the core with the profile's state key.
    var inbox: Data
    var contacts: [Contact] = []
    var messages: [ChatMessage] = []
    /// Sealed state of the on-device demo contact, if one was started.
    var demoContact: Data?
    /// When this profile's wallet was created, or for a restored profile the date the user
    /// picked. The wallet starts scanning the chain from about this point.
    var walletCreated: Date?
    /// Whether the user has opened the recovery phrase screen for this profile.
    var recoveryPhraseShown: Bool?
    /// True when this profile came from a recovery phrase: its wallet scans from
    /// `walletCreated` instead of starting at the current chain height.
    var walletRestored: Bool?
    /// Server and Tor choices for this profile's wallet. Nil means the defaults.
    var walletSettings: WalletSettings?
    /// Wallet transactions whose memos have already been read, oldest first. Lets every sync
    /// pick up exactly the transactions it hasn't seen yet, in whatever order they're found.
    var processedTransactions: [Data]?
}

/// A profile being restored from its recovery phrase, waiting for PINs to be set.
struct RestoredProfile: Hashable, Sendable {
    let secret: Data
    let created: Date
}

struct Contact: Codable, Identifiable, Hashable {
    /// The contact's public identity key (32 bytes). Used to find the session; never shown.
    let id: Data
    /// A local nickname. Stays on this phone; never sent to anyone.
    var name: String
    var verified = false
    var isDemo = false
    let added: Date
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        /// Saved; the transaction is being built and broadcast.
        case sending
        /// Accepted by the server, not yet in a block.
        case sent
        /// Mined: the message is on the chain and readable by the contact.
        case delivered
        /// Not broadcast, or expired unmined. Can be sent again unchanged.
        case failed
        case received
    }

    let id: UUID
    let peer: Data
    let outgoing: Bool
    let text: String
    let date: Date
    var status: Status
    /// Number of 512-byte memos this message used on the wire (outgoing only).
    var memoCount: Int
    /// The transaction that carries this message, once broadcast (outgoing only).
    var txid: Data?
    /// The encrypted memos, kept until the message is delivered so a failed send can be
    /// retried without advancing the ratchet again (outgoing only).
    var pendingMemos: [Data]?

    static func outgoing(_ text: String, to peer: Data, memos: Int) -> ChatMessage {
        ChatMessage(id: UUID(), peer: peer, outgoing: true, text: text, date: Date(),
                    status: .sent, memoCount: memos)
    }

    static func incoming(_ text: String, from peer: Data, date: Date = Date()) -> ChatMessage {
        ChatMessage(id: UUID(), peer: peer, outgoing: false, text: text, date: date,
                    status: .received, memoCount: 0)
    }
}
