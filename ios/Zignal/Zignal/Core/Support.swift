import Foundation
import Security

/// Errors raised by the app layer. Messages are safe to show: they never include key
/// material, PINs or message content.
enum ZignalError: LocalizedError {
    case randomUnavailable
    case keychain(OSStatus)
    case damagedProfile
    case messageTooLong
    case invalidRecoveryPhrase
    case walletNotReady
    case walletMismatch
    case notEnoughFunds
    case sendRejected(String)
    case invalidInvite
    case ownInvite
    case invalidAddress

    var errorDescription: String? {
        switch self {
        case .randomUnavailable: "The system random number generator is unavailable."
        case .keychain: "The Keychain is unavailable. Unlock your phone and try again."
        case .damagedProfile: "Saved data could not be decrypted. It may be damaged."
        case .messageTooLong: "This message is too long. Split it into shorter messages."
        case .invalidRecoveryPhrase: "That isn't a valid 24-word recovery phrase. Check each word."
        case .walletNotReady: "The wallet is still starting. Try again in a moment."
        case .walletMismatch: "The wallet on this phone doesn't belong to this profile."
        case .notEnoughFunds: "Not enough ZEC in this wallet yet. Add funds and wait for them to confirm."
        case .sendRejected(let reason): "The network didn't accept the message: \(reason)"
        case .invalidInvite: "That isn't a valid Zignal invite. Check that you copied all of it."
        case .ownInvite: "That's your own invite. Share it with your contact instead."
        case .invalidAddress: "This contact's address isn't a shielded Zcash address, so nothing was sent."
        }
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
