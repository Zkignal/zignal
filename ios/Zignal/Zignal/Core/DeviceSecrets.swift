import CryptoKit
import Foundation
import Security

/// The PIN vault and the device key for the profile files, kept in the Keychain sealed by a key
/// in this phone's Secure Enclave.
///
/// The Secure Enclave key never leaves the chip. The Keychain holds only an opaque handle that
/// works on this phone, while it's unlocked, for this app. So a copy of the Keychain taken off
/// the phone can't be opened anywhere else, and the PINs can't be guessed offline.
///
///     sealed = 0x01 || ephemeral P-256 public key (65 bytes) || AES-GCM(key, secret)
///     key    = HKDF-SHA256(ECDH(ephemeral key, Secure Enclave key), salt: ephemeral public key,
///                          info: "zkw/app/seal-key/v1" || label || Secure Enclave public key)
///
/// Items from older versions, stored without the seal, move over the first time they're read:
/// the sealed copy is written, read back and opened, and only then is the plain copy deleted.
/// If any step fails, the plain copy stays as it was and the move is tried again next time.
///
/// Without a Secure Enclave, debug builds use a software key kept in the Keychain (so a copy of
/// the Keychain includes it); release builds refuse.
struct DeviceSecrets: Sendable {
    enum Secret: CaseIterable, Sendable {
        case vault
        case fileKey

        var plainItem: Keychain.Item {
            switch self {
            case .vault: return .vault
            case .fileKey: return .fileKey
            }
        }

        var sealedItem: Keychain.Item {
            switch self {
            case .vault: return .sealedVault
            case .fileKey: return .sealedFileKey
            }
        }

        var label: Data {
            switch self {
            case .vault: return Data("zkw/app/sealed-vault/v1".utf8)
            case .fileKey: return Data("zkw/app/sealed-file-key/v1".utf8)
            }
        }
    }

    /// The key that seals and opens.
    enum SealKey {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey) // debug builds without a Secure Enclave, and tests

        var publicKey: P256.KeyAgreement.PublicKey {
            switch self {
            case .enclave(let key): return key.publicKey
            case .software(let key): return key.publicKey
            }
        }

        func sharedSecret(with other: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            switch self {
            case .enclave(let key): return try key.sharedSecretFromKeyAgreement(with: other)
            case .software(let key): return try key.sharedSecretFromKeyAgreement(with: other)
            }
        }
    }

    /// A sealed item that doesn't open: damaged, sealed under another key, or its key is gone.
    struct Unreadable: Error {}

    /// The app's own items.
    static let app = DeviceSecrets(service: Keychain.appService)

    /// The Keychain service the items are stored under. Tests use their own.
    let service: String
    let useSecureEnclave: Bool

    init(service: String, useSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.service = service
        self.useSecureEnclave = useSecureEnclave
    }

    /// Returns nil when there's no such secret.
    func read(_ secret: Secret) throws -> Data? {
        try locked {
            let plain = try Keychain.read(secret.plainItem, service: service)
            if let sealed = try Keychain.read(secret.sealedItem, service: service) {
                do {
                    let opened = try open(sealed, as: secret)
                    // The sealed copy is the newer one. A plain copy next to it is left from a
                    // move or a write whose last step didn't finish.
                    if plain != nil { try? Keychain.delete(secret.plainItem, service: service) }
                    return opened
                } catch is Unreadable {
                    guard plain != nil else { throw ZignalError.damagedProfile }
                    // A move was cut short before its sealed copy could be opened: the plain
                    // copy is still the real one.
                }
            }
            guard let original = plain else { return nil }
            // From an older version. If the move fails, the plain copy works as before and the
            // move is tried again next time.
            try? move(original, to: secret)
            return original
        }
    }

    /// Seals and stores a secret, replacing any earlier copy, sealed or plain.
    func write(_ data: Data, to secret: Secret) throws {
        try locked {
            do {
                try Keychain.write(try seal(data, as: secret), to: secret.sealedItem, service: service)
            } catch is Unreadable {
                throw ZignalError.damagedProfile
            }
            // An older plain copy must not outlive this write: after a panic wipe it would still
            // hold the wiped profile's slot.
            try Keychain.delete(secret.plainItem, service: service)
        }
    }

    /// Deletes a secret, sealed and plain.
    func delete(_ secret: Secret) throws {
        try locked {
            try Keychain.delete(secret.sealedItem, service: service)
            try Keychain.delete(secret.plainItem, service: service)
        }
    }

    /// Deletes both secrets and the sealing key. Setup starts here, so every setup gets a new key.
    func removeAll() throws {
        try locked {
            for secret in Secret.allCases { try delete(secret) }
            try Keychain.delete(.sealKey, service: service)
        }
    }

    // MARK: - Sealing

    private static let format: UInt8 = 1
    private static let enclaveKey: UInt8 = 1
    private static let softwareKey: UInt8 = 2
    private static let publicKeyLength = 65 // x9.63, uncompressed
    private static let kdfLabel = Data("zkw/app/seal-key/v1".utf8)

    static func seal(_ data: Data, to key: SealKey, label: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let box = try AES.GCM.seal(data, using: derive(shared, ephemeralPublic, key.publicKey, label),
                                   authenticating: Data([format]) + label)
        guard let combined = box.combined else { throw ZignalError.damagedProfile }
        return Data([format]) + ephemeralPublic + combined
    }

    static func open(_ sealed: Data, with key: SealKey, label: Data) throws -> Data {
        guard sealed.count >= 1 + publicKeyLength + 12 + 16, sealed.first == format else {
            throw Unreadable()
        }
        let ephemeralPublic = Data(sealed.dropFirst().prefix(publicKeyLength))
        let ephemeral: P256.KeyAgreement.PublicKey
        do {
            ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublic)
        } catch {
            throw Unreadable()
        }
        // Errors from the Secure Enclave itself pass through: they don't mean the item is damaged.
        let shared = try key.sharedSecret(with: ephemeral)
        let symmetric = derive(shared, ephemeralPublic, key.publicKey, label)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(sealed.dropFirst(1 + publicKeyLength)))
            return try AES.GCM.open(box, using: symmetric, authenticating: Data([format]) + label)
        } catch {
            throw Unreadable()
        }
    }

    private static func derive(_ shared: SharedSecret, _ ephemeralPublic: Data,
                               _ recipient: P256.KeyAgreement.PublicKey, _ label: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic,
                                       sharedInfo: kdfLabel + label + recipient.x963Representation,
                                       outputByteCount: 32)
    }

    private func seal(_ data: Data, as secret: Secret) throws -> Data {
        let key: SealKey
        if let existing = try loadKey() {
            key = existing
        } else {
            // A new key would strand anything sealed under a lost one, so one is made only while
            // nothing is sealed yet.
            let sealedSomething = try Secret.allCases.contains {
                try Keychain.read($0.sealedItem, service: service) != nil
            }
            guard !sealedSomething else { throw ZignalError.damagedProfile }
            key = try newKey()
        }
        return try Self.seal(data, to: key, label: secret.label)
    }

    private func open(_ sealed: Data, as secret: Secret) throws -> Data {
        guard let key = try loadKey() else { throw Unreadable() }
        return try Self.open(sealed, with: key, label: secret.label)
    }

    /// Writes the sealed copy, reads it back and opens it, and only then deletes the plain copy.
    private func move(_ plain: Data, to secret: Secret) throws {
        try Keychain.write(try seal(plain, as: secret), to: secret.sealedItem, service: service)
        guard let stored = try Keychain.read(secret.sealedItem, service: service),
              try open(stored, as: secret) == plain else { throw Unreadable() }
        try Keychain.delete(secret.plainItem, service: service)
    }

    // MARK: - The sealing key

    private func loadKey() throws -> SealKey? {
        guard let stored = try Keychain.read(.sealKey, service: service) else { return nil }
        guard let kind = stored.first else { throw Unreadable() }
        let body = Data(stored.dropFirst())
        switch kind {
        case Self.enclaveKey:
            return .enclave(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body))
        case Self.softwareKey:
            #if DEBUG
            do {
                return .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: body))
            } catch {
                throw Unreadable()
            }
            #else
            throw ZignalError.noSecureEnclave
            #endif
        default:
            throw Unreadable()
        }
    }

    private func newKey() throws -> SealKey {
        let key: SealKey
        let stored: Data
        if useSecureEnclave {
            // Usable only while the phone is unlocked, never moved to another device, and with no
            // Face ID prompt: Zignal's own PIN screen stays the only prompt.
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil)
            else { throw ZignalError.noSecureEnclave }
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            key = .enclave(enclave)
            stored = Data([Self.enclaveKey]) + enclave.dataRepresentation
        } else {
            #if DEBUG
            let software = P256.KeyAgreement.PrivateKey()
            key = .software(software)
            stored = Data([Self.softwareKey]) + software.rawRepresentation
            #else
            throw ZignalError.noSecureEnclave
            #endif
        }
        try Keychain.write(stored, to: .sealKey, service: service)
        return key
    }

    // MARK: - One at a time

    /// One call at a time across the app, so a move or a new key never races another call.
    private static let lock = NSRecursiveLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }
}
