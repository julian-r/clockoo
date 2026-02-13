import Foundation
import Security

/// Simple macOS Keychain wrapper for storing API keys
/// Service: "com.clockoo", Account: the account ID
enum KeychainHelper {
    static let service = "com.clockoo"

    /// Retrieve an API key from Keychain
    static func getAPIKey(for accountId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store an API key in Keychain (overwrites if exists)
    static func setAPIKey(_ apiKey: String, for accountId: String) throws {
        let data = apiKey.data(using: .utf8)!

        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unableToStore(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unableToStore(status: updateStatus)
        }
    }

    /// Delete an API key from Keychain
    static func deleteAPIKey(for accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error, LocalizedError {
    case unableToStore(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToStore(let status):
            return "Failed to store API key in Keychain (status: \(status))"
        }
    }
}
