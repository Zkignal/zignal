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
        case sent
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

    static func outgoing(_ text: String, to peer: Data, memos: Int) -> ChatMessage {
        ChatMessage(id: UUID(), peer: peer, outgoing: true, text: text, date: Date(),
                    status: .sent, memoCount: memos)
    }

    static func incoming(_ text: String, from peer: Data) -> ChatMessage {
        ChatMessage(id: UUID(), peer: peer, outgoing: false, text: text, date: Date(),
                    status: .received, memoCount: 0)
    }
}
