import Foundation
import Security

/// Credentials are persisted only in Keychain. A failed save never writes plaintext.
enum KeychainStore {
    static func value(for account: String) -> String {
        if let value = read(from: HerdrAppIdentity.keychainService, account: account) {
            UserDefaults.standard.removeObject(forKey: legacyFallbackKey(for: account))
            return value
        }
        // Private upgrades may name their prior service in the local config.
        // Retain the source credential until the destination save succeeds.
        if let oldService = HerdrAppIdentity.legacyKeychainService,
           oldService != HerdrAppIdentity.keychainService,
           let value = read(from: oldService, account: account),
           set(value, for: account) == errSecSuccess {
            return value
        }
        // Migrate plaintext left by older builds, but never create new fallback entries.
        if let value = UserDefaults.standard.string(forKey: legacyFallbackKey(for: account)),
           !value.isEmpty,
           set(value, for: account) == errSecSuccess {
            return value
        }
        return ""
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> OSStatus {
        let key = query(service: HerdrAppIdentity.keychainService, account: account)
        if value.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            UserDefaults.standard.removeObject(forKey: legacyFallbackKey(for: account))
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = key
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: legacyFallbackKey(for: account))
        }
        return status
    }

    static func removeValue(for account: String) { set("", for: account) }

    private static func read(from service: String, account: String) -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func query(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func legacyFallbackKey(for account: String) -> String {
        "herdr.keychainFallback.\(account)"
    }
}
