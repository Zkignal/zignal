import CryptoKit
import Foundation

/// Keys for one unlocked profile, derived by zkw-core from the profile secret.
/// Held in memory only while the profile is unlocked.
struct ProfileKeyset {
    let identitySeed: Data
    let stateKey: Data

    init(secret: Data) throws {
        let keys = try profileKeys(profileSecret: secret)
        identitySeed = keys.identitySeed
        stateKey = keys.stateKey
    }

    /// An independent subkey for app-level use (HKDF-SHA256, domain-separated by `label`).
    func subkey(_ label: String, count: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: stateKey),
                               info: Data(label.utf8), outputByteCount: count)
    }

    func subkeyBytes(_ label: String, count: Int = 32) -> Data {
        subkey(label, count: count).withUnsafeBytes { Data($0) }
    }
}

/// Encrypted profile files, built so the real and decoy profiles can't be told apart on disk.
///
/// Every file is the same size and is one sealed, opaque block:
///
///     outer = ChaCha20-Poly1305(device key, block)
///     block = header || body || random bytes up to the common size
///     header = ChaCha20-Poly1305(profile key, body length)     (fixed 32 bytes)
///     body   = ChaCha20-Poly1305(profile key, JSON)
///
/// The device key lives in the Keychain (this device only). The profile key comes from that
/// profile's own PIN, so even with the device key nobody can see where a profile's data ends,
/// or how much there is, without that PIN.
///
/// Every save re-seals the outer layer of every file with fresh nonces, writes all of them at
/// one common size and gives them the same timestamps, so all files change together whichever
/// profile is in use. File names come from the profile key, and there are always at least two
/// files, so a lone file can't mark itself as the one in use. Known limit: someone holding the
/// device key and two snapshots can still see which block changed.
///
/// Files use complete data protection and the folder is excluded from device backups.
/// Chat state must never come back from a backup: restoring an old ratchet state could reuse
/// message keys.
struct ProfileStore {
    enum DeviceKeySource {
        case keychain
        case fixed(SymmetricKey) // tests only
    }

    let directory: URL
    let deviceKeySource: DeviceKeySource

    static let minBucket = 256 * 1024
    static let minimumFiles = 2
    private static let headerLength = 4 + 28 // UInt32 + ChaChaPoly nonce and tag
    private static let headerAD = Data("zkw/app/profile-header/v1".utf8)
    private static let bodyAD = Data("zkw/app/profile-body/v1".utf8)
    private static let outerAD = Data("zkw/app/profile-outer/v1".utf8)

    static func standard() -> ProfileStore {
        ProfileStore(directory: URL.applicationSupportDirectory
                        .appending(path: "zkw", directoryHint: .isDirectory),
                     deviceKeySource: .keychain)
    }

    /// Creates the folder if needed and keeps it out of backups.
    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func removeAll() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: file)
        }
    }

    /// Returns nil when this profile has no file on this device yet.
    func load(_ keys: ProfileKeyset) throws -> ProfileData? {
        let url = fileURL(for: keys)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let sealed = try Data(contentsOf: url)
        let deviceKey = try deviceKey(createIfMissing: false)
        do {
            let block = try Self.open(sealed, key: deviceKey, ad: Self.outerAD)
            let json = try Self.openBlock(block, key: keys.subkey(KeyLabel.fileKey))
            return try JSONDecoder().decode(ProfileData.self, from: json)
        } catch {
            throw ZignalError.damagedProfile
        }
    }

    /// Saves one profile and re-seals every other file alongside it.
    func save(_ data: ProfileData, _ keys: ProfileKeyset) throws {
        try write([(data, keys)])
    }

    /// Replaces everything in the folder with these profiles. Used at setup.
    func reset(with profiles: [(ProfileData, ProfileKeyset)]) throws {
        try removeAll()
        try write(profiles)
    }

    func fileURL(for keys: ProfileKeyset) -> URL {
        fileURL(named: Self.hex(keys.subkeyBytes(KeyLabel.fileName, count: 16)))
    }

    // MARK: - Writing

    private func write(_ profiles: [(ProfileData, ProfileKeyset)]) throws {
        let existing = try profileFiles()
        // A new device key is only made when there are no files it would strand.
        let deviceKey = try deviceKey(createIfMissing: existing.isEmpty)

        // Profiles being saved: header and body, sealed under each profile's own key.
        var updated: [URL: Data] = [:]
        for (data, keys) in profiles {
            let json = try JSONEncoder().encode(data)
            let key = keys.subkey(KeyLabel.fileKey)
            let length = withUnsafeBytes(of: UInt32(json.count).bigEndian) { Data($0) }
            let header = try ChaChaPoly.seal(length, using: key, authenticating: Self.headerAD).combined
            let body = try ChaChaPoly.seal(json, using: key, authenticating: Self.bodyAD).combined
            updated[fileURL(for: keys)] = header + body
        }

        // Every other file we can open is carried over as an opaque block. A file we can't
        // open (damaged, or not ours) is left alone rather than deleted.
        var carried: [URL: Data] = [:]
        for url in existing where updated[url] == nil {
            if let block = try? Self.open(Data(contentsOf: url), key: deviceKey, ad: Self.outerAD) {
                carried[url] = block
            }
        }
        while updated.count + carried.count < Self.minimumFiles {
            let name = Self.hex(try secureRandom(16))
            carried[fileURL(named: name)] = Data() // filler: becomes all random bytes below
        }

        // One common size for every file. It never shrinks, so it can't reveal deletions.
        let needed = (updated.values.map(\.count) + carried.values.map(\.count)).max() ?? 0
        var size = Self.minBucket
        while size < needed { size *= 2 }

        // Profiles being saved go first; timestamps are evened out even if a write fails.
        defer { equalizeTimestamps() }
        for (url, block) in Array(updated) + Array(carried) {
            let fill = try secureRandom(size - block.count)
            let sealed = try ChaChaPoly.seal(block + fill, using: deviceKey,
                                             authenticating: Self.outerAD).combined
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    private func deviceKey(createIfMissing: Bool) throws -> SymmetricKey {
        switch deviceKeySource {
        case .fixed(let key):
            return key
        case .keychain:
            if let existing = try Keychain.read(.fileKey) { return SymmetricKey(data: existing) }
            guard createIfMissing else { throw ZignalError.damagedProfile }
            let fresh = try secureRandom(32)
            try Keychain.write(fresh, to: .fileKey)
            return SymmetricKey(data: fresh)
        }
    }

    /// Our files only: 32 lowercase hex characters. Skips anything else, such as a temporary
    /// file left behind by an interrupted atomic write.
    private func profileFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.count == 32 && $0.allSatisfy { "0123456789abcdef".contains($0) } }
            .map { fileURL(named: $0) }
    }

    private func equalizeTimestamps() {
        let now = Date()
        guard let files = try? profileFiles() else { return }
        for url in files {
            try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now],
                                                   ofItemAtPath: url.path)
        }
    }

    private func fileURL(named name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: - Helpers

    /// Reads a profile's JSON out of a decrypted block: header (length), then body.
    static func openBlock(_ block: Data, key: SymmetricKey) throws -> Data {
        guard block.count >= headerLength else { throw ZignalError.damagedProfile }
        let header = Data(block.prefix(headerLength))
        let lengthBytes = try open(header, key: key, ad: headerAD)
        guard lengthBytes.count == 4 else { throw ZignalError.damagedProfile }
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let bodyLength = length + 28
        guard bodyLength <= block.count - headerLength else { throw ZignalError.damagedProfile }
        let body = Data(block.dropFirst(headerLength).prefix(bodyLength))
        return try open(body, key: key, ad: bodyAD)
    }

    private static func open(_ combined: Data, key: SymmetricKey, ad: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: key, authenticating: ad)
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
