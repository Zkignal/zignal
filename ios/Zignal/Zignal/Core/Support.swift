import Foundation
import Security

/// Errors raised by the app layer. Messages are safe to show: they never include key
/// material, PINs or message content.
enum ZignalError: LocalizedError {
    case randomUnavailable
    case keychain(OSStatus)
    case noSecureEnclave
    case damagedProfile
    case messageTooLong
    case invalidRecoveryPhrase
    case walletNotReady
    case walletCatchingUp
    case clocksDisagree
    case walletMismatch
    case notEnoughFunds
    case notEnoughToPrepare(minimum: Int64)
    case sendRejected(String)
    /// The light server's own words for refusing a transaction (shown through `ServerText`).
    case serverRefused(String)
    case invalidInvite
    case ownInvite
    case inviteAlreadyUsed
    case existingContact
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .randomUnavailable: "The system random number generator is unavailable."
        case .keychain: "The Keychain is unavailable. Unlock your phone and try again."
        case .noSecureEnclave: "This device has no Secure Enclave, so Zignal can't protect your PINs on it."
        case .damagedProfile: "Saved data could not be decrypted. It may be damaged."
        case .messageTooLong: "This message is too long. Split it into shorter messages."
        case .invalidRecoveryPhrase: "That isn't a valid 24-word recovery phrase. Check each word."
        case .walletNotReady: "The wallet is still starting. Try again in a moment."
        case .walletCatchingUp: "The wallet is still catching up with the network. Try again once it says Up to date."
        case .clocksDisagree: "This server's block times don't match the chain, so an invite can't be made right now. Choose another server under Network, then try again."
        case .walletMismatch: "The wallet on this phone doesn't belong to this profile."
        case .notEnoughFunds: "Not enough ZEC in this wallet yet. Add funds and wait for them to confirm."
        case .notEnoughToPrepare(let minimum):
            "Prepare needs at least \(String(format: "%.4f", Double(minimum) / 100_000_000)) ZEC that has confirmed. You can still send single messages without it."
        case .sendRejected(let reason): "The network didn't accept the message: \(reason)"
        case .serverRefused(let words): ServerText.refusal(words)
        case .invalidInvite: "That isn't a valid Zignal invite. Check that you copied all of it."
        case .ownInvite: "That's your own invite. Share it with your contact instead."
        case .inviteAlreadyUsed: "You've already used this invite. An invite works only once: ask your contact for a new one if you need to start over."
        case .existingContact: "You already have a chat with this contact."
        case .invalidAddress: "This contact's address isn't a valid shielded Zcash address with an Orchard receiver, so nothing was sent."
        }
    }
}

/// Words that came from the light server, made safe to show. The server chooses them, so they
/// are never shown as they came: one line of plain ASCII letters, digits and punctuation (no
/// quotation marks), at most `limit` characters, inside quotation marks and named as the
/// server's answer.
enum ServerText {
    static let limit = 120

    /// `text` as one plain line: anything that isn't a printable ASCII character (line breaks,
    /// other alphabets, invisible characters) or is a quotation mark ends a word; at most `limit`
    /// characters.
    static func plain(_ text: String) -> String {
        var words: [String] = []
        var word = ""
        for scalar in text.unicodeScalars {
            if scalar.value > 0x20, scalar.value < 0x7F, scalar.value != 0x22 {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        let line = words.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "..." : line
    }

    /// What the app shows when the light server refuses a transaction.
    static func refusal(_ text: String) -> String {
        let said = plain(text)
        return said.isEmpty
            ? "The light server didn't accept the message."
            : "The light server didn't accept the message. Its answer: \"\(said)\""
    }
}

extension Data {
    /// Lowercase hex, two characters per byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Cryptographically secure random bytes from the system CSPRNG.
func secureRandom(_ count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw ZignalError.randomUnavailable
    }
    return Data(bytes)
}

/// Current time in unix seconds, the unit zkw-core expects.
func unixNow() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
}

/// Domain-separation labels for keys the app derives from a profile's state key.
/// Each label yields an independent key; changing one is a breaking storage change.
enum KeyLabel {
    static let fileName = "zkw/app/file-name/v1"
    static let fileKey = "zkw/app/file-key/v1"
    static let demoIdentity = "zkw/app/demo-identity/v1"
    static let demoState = "zkw/app/demo-state/v1"
    /// Names this profile's wallet files on disk.
    static let walletAlias = "zkw/app/wallet-alias/v1"
}
