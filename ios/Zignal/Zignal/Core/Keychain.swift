import Foundation
import Security

/// Keychain storage for the PIN vault, the device key, the Secure Enclave key that seals both,
/// and the wrong-PIN counter. The vault and the device key go through `DeviceSecrets`, which
/// seals them; the wrong-PIN counter is stored as it is.
///
/// Items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable only while the phone
/// is unlocked, never synced to iCloud Keychain, and never moved to a different device.
enum Keychain {
    enum Item: String, CaseIterable {
        /// The PIN vault (both profile secrets, sealed under the unlock, duress and panic PINs),
        /// as older versions stored it. Moved to `sealedVault` the first time it's read.
        case vault
        /// The wrong-PIN counter.
        case attempts
        /// The device key for the outer layer of the profile files, as older versions stored it.
        /// Moved to `sealedFileKey` the first time it's read.
        case fileKey
        /// The handle of the Secure Enclave key that seals the two items below.
        case sealKey
        /// The PIN vault, sealed by the Secure Enclave key.
        case sealedVault
        /// The device key, sealed by the Secure Enclave key.
        case sealedFileKey
    }

    /// The app's own items. Tests use other services, so they never touch these.
    static let appService = "zignal"

    static func read(_ item: Item, service: String = Keychain.appService) throws -> Data? {
        var query = baseQuery(item, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw ZignalError.keychain(status)
        }
    }

    static func write(_ data: Data, to item: Item, service: String = Keychain.appService) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(item, service: service) as CFDictionary,
                                   attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = baseQuery(item, service: service).merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw ZignalError.keychain(added) }
        } else if status != errSecSuccess {
            throw ZignalError.keychain(status)
        }
    }

    static func delete(_ item: Item, service: String = Keychain.appService) throws {
        let status = SecItemDelete(baseQuery(item, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZignalError.keychain(status)
        }
    }

    private static func baseQuery(_ item: Item, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}
