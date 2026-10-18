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

    var errorDescription: String? {
        switch self {
        case .randomUnavailable: "The system random number generator is unavailable."
        case .keychain: "The Keychain is unavailable. Unlock your phone and try again."
        case .damagedProfile: "Saved data could not be decrypted. It may be damaged."
        case .messageTooLong: "This message is too long. Split it into shorter messages."
        case .invalidRecoveryPhrase: "That isn't a valid 24-word recovery phrase. Check each word."
        }
    }
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
}
