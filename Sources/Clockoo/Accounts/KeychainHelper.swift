import Foundation
import Security

/// Simple macOS Keychain wrapper for storing API keys.
/// Uses SecTrustedApplication ACL so the current app can access
/// its own items without prompts across rebuilds.
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
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store an API key in Keychain.
    /// Creates a trusted application ACL so the current binary
    /// can read the item without interactive prompts.
    static func setAPIKey(_ apiKey: String, for accountId: String) throws {
        let data = apiKey.data(using: .utf8)!

        // Delete existing first (clean slate for ACL)
        deleteAPIKey(for: accountId)

        // Build trusted app ACL for current application (nil = self)
        let acl = createTrustedAccess(label: "Clockoo: \(accountId)")

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecAttrLabel as String: "Clockoo: \(accountId)",
            kSecValueData as String: data,
        ]
        if let acl {
            addQuery[kSecAttrAccess as String] = acl
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore(status: status)
        }
    }

    /// Delete an API key from Keychain
    static func deleteAPIKey(for accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Create a SecAccess that trusts the current application.
    /// This avoids Keychain password prompts when reading back the item.
    @available(macOS, deprecated: 10.10)
    private static func createTrustedAccess(label: String) -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApp) == errSecSuccess,
              let app = trustedApp
        else { return nil }

        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [app] as CFArray, &access) == errSecSuccess
        else { return nil }

        return access
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
