import Foundation
import Security

/// Secrets for integrations, kept in the macOS Keychain: readable only while the Mac is unlocked,
/// never synced to iCloud, never written to the database or logs.
public struct CredentialStore: Sendable {
    public struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        public var errorDescription: String? {
            "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
        }
    }

    let service: String

    public init(service: String = "com.nrvl.network.integration") {
        self.service = service
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable] = false
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func get(account: String) throws -> String? {
        var item = query(account)
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
