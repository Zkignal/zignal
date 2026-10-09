import Foundation
import Security

/// Keychain storage for the duress vault and the wrong-PIN counter.
///
/// Items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: readable only while the phone
/// is unlocked, never synced to iCloud Keychain, and never moved to a different device.
enum Keychain {
    enum Item: String, CaseIterable {
        /// The duress vault (both profile secrets, each sealed under its PIN).
        case vault
        /// The wrong-PIN counter.
        case attempts
        /// The device key for the outer layer of the profile files.
        case fileKey
    }

    private static let service = "zignal"

    static func read(_ item: Item) throws -> Data? {
        var query = baseQuery(item)
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

    static func write(_ data: Data, to item: Item) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(item) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = baseQuery(item).merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw ZignalError.keychain(added) }
        } else if status != errSecSuccess {
            throw ZignalError.keychain(status)
        }
    }

    static func delete(_ item: Item) throws {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZignalError.keychain(status)
        }
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}
