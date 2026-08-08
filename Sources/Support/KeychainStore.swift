import Foundation
import Security

/// Minimal wrapper around a single generic-password Keychain item.
enum KeychainStore {
    static let service = "com.local.Cue"
    /// Service used while the app was WhisperDesk; read as a fallback so
    /// existing API keys survive the rename, then rewritten under `service`.
    private static let legacyService = "com.local.WhisperDesk"

    static func read(account: String) -> String? {
        if let value = read(account: account, service: service) {
            return value
        }
        guard let legacy = read(account: account, service: legacyService) else {
            return nil
        }
        write(legacy, account: account)
        return legacy
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard !value.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        // Cue only reads keys while in the foreground, so the item
        // never needs to be readable before unlock. Setting the attribute on
        // update too migrates items created by earlier builds.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // A silently failed write means the key vanishes on next launch.
            NSLog("Cue: Keychain write for %@ failed with status %d.", account, status)
        }
    }
}
