import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Schlüsselbund-Fehler (\(status))."
        }
    }
}

enum KeychainStore {
    private static let service = "de.onlinemarktplatz.OMNewsWatcher"
    private static let account = "github-token"

    static func readToken() async -> String? {
        await Task.detached(priority: .utility) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess,
                  let data = result as? Data,
                  let token = String(data: data, encoding: .utf8)
            else {
                return nil
            }

            return token
        }.value
    }

    static func saveToken(_ token: String) async throws {
        try await Task.detached(priority: .utility) {
            let data = Data(token.utf8)
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                attributes as CFDictionary
            )

            if updateStatus == errSecSuccess {
                return
            }

            if updateStatus != errSecItemNotFound {
                throw KeychainError.unexpectedStatus(updateStatus)
            }

            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        }.value
    }

    static func deleteToken() async throws {
        try await Task.detached(priority: .utility) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }.value
    }
}
