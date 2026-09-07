import Foundation
import Security

enum MacKeychainBackend: String, Sendable {
    case login
    case dataProtection = "data-protection"

    var alternate: Self { self == .login ? .dataProtection : .login }
}

struct MacKeychainRead {
    let status: OSStatus
    let value: String?
}

protocol MacKeychainStorage {
    func read(backend: MacKeychainBackend, service: String, account: String) -> MacKeychainRead
    func write(_ value: String, backend: MacKeychainBackend, service: String, account: String) -> OSStatus
    func delete(backend: MacKeychainBackend, service: String, account: String) -> OSStatus
}

/// Migrates only after a secure write succeeds. Failed reads never erase sources.
struct MacCredentialPersistence {
    let backend: MacKeychainBackend
    let service: String
    let legacyService: String?
    let defaults: UserDefaults
    let storage: any MacKeychainStorage

    func value(for account: String) -> String {
        guard !defaults.bool(forKey: deletionKey(account)) else { return "" }
        let current = storage.read(backend: backend, service: service, account: account)
        if current.status == errSecSuccess, let value = current.value, !value.isEmpty {
            defaults.removeObject(forKey: fallbackKey(account))
            return value
        }
        guard current.status == errSecItemNotFound else { return "" }

        for source in migrationSources {
            let previous = storage.read(backend: source.backend, service: source.service, account: account)
            if previous.status == errSecSuccess, let value = previous.value, !value.isEmpty {
                return set(value, for: account) == errSecSuccess ? value : ""
            }
            // An unprovisioned Mac cannot query the optional DP source. Other
            // access errors (including a locked Keychain) must remain failures.
            guard previous.status == errSecItemNotFound
                    || (source.backend == .dataProtection && previous.status == errSecMissingEntitlement)
            else { return "" }
        }
        if let value = defaults.string(forKey: fallbackKey(account)), !value.isEmpty,
           set(value, for: account) == errSecSuccess {
            return value
        }
        return ""
    }

    @discardableResult
    func set(_ value: String, for account: String) -> OSStatus {
        guard !value.isEmpty else { return remove(account) }
        let status = storage.write(value, backend: backend, service: service, account: account)
        if status == errSecSuccess {
            defaults.removeObject(forKey: fallbackKey(account))
            defaults.removeObject(forKey: deletionKey(account))
        }
        return status
    }

    private func remove(_ account: String) -> OSStatus {
        let status = storage.delete(backend: backend, service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else { return status }
        // Retained migration sources must never restore an intentionally deleted
        // credential, even if a former backend is currently inaccessible.
        defaults.set(true, forKey: deletionKey(account))
        defaults.removeObject(forKey: fallbackKey(account))
        var failure: OSStatus?
        for source in migrationSources {
            let result = storage.delete(backend: source.backend, service: source.service, account: account)
            if result != errSecSuccess && result != errSecItemNotFound
                && !(source.backend == .dataProtection && result == errSecMissingEntitlement) {
                failure = failure ?? result
            }
        }
        return failure ?? errSecSuccess
    }

    private var migrationSources: [(backend: MacKeychainBackend, service: String)] {
        var sources = [(backend.alternate, service)]
        if let legacyService, !legacyService.isEmpty, legacyService != service {
            sources += [(backend, legacyService), (backend.alternate, legacyService)]
        }
        return sources
    }

    private func fallbackKey(_ account: String) -> String { "herdr.keychainFallback.\(account)" }
    private func deletionKey(_ account: String) -> String { "herdr.keychainDeleted.\(account)" }
}

/// Credentials use the configured secure Keychain backend, never plaintext writes.
enum KeychainStore {
    static func value(for account: String) -> String { persistence.value(for: account) }
    @discardableResult
    static func set(_ value: String, for account: String) -> OSStatus { persistence.set(value, for: account) }
    static func removeValue(for account: String) { set("", for: account) }

    private static var persistence: MacCredentialPersistence {
        MacCredentialPersistence(
            backend: HerdrAppIdentity.keychainBackend,
            service: HerdrAppIdentity.keychainService,
            legacyService: HerdrAppIdentity.legacyKeychainService,
            defaults: .standard,
            storage: SystemMacKeychainStorage()
        )
    }

    /// The diagnostic and production store share the exact namespace and backend.
    static func secureItemQuery(for account: String) -> [String: Any] {
        MacKeychainQueries.matching(backend: HerdrAppIdentity.keychainBackend, service: HerdrAppIdentity.keychainService, account: account)
    }
}

enum MacKeychainQueries {
    static func matching(backend: MacKeychainBackend, service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: backend == .dataProtection,
        ]
    }

    static func insertion(_ query: [String: Any], data: Data, backend: MacKeychainBackend) -> (status: OSStatus, attributes: [String: Any]) {
        var attributes = query
        attributes[kSecValueData as String] = data
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        } else {
            // File-based Keychain ACLs are distinct from DP access groups.
            // A nil trusted list trusts only the creating application.
            var access: SecAccess?
            let status = SecAccessCreate("Herdr server credential" as CFString, nil, &access)
            guard status == errSecSuccess, let access else { return (status == errSecSuccess ? errSecParam : status, [:]) }
            attributes[kSecAttrAccess as String] = access
        }
        return (errSecSuccess, attributes)
    }
}

struct SystemMacKeychainStorage: MacKeychainStorage {
    func read(backend: MacKeychainBackend, service: String, account: String) -> MacKeychainRead {
        var query = MacKeychainQueries.matching(backend: backend, service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return MacKeychainRead(status: status, value: nil) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return MacKeychainRead(status: errSecDecode, value: nil)
        }
        return MacKeychainRead(status: errSecSuccess, value: value)
    }

    func write(_ value: String, backend: MacKeychainBackend, service: String, account: String) -> OSStatus {
        let query = MacKeychainQueries.matching(backend: backend, service: service, account: account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        let insert = MacKeychainQueries.insertion(query, data: data, backend: backend)
        guard insert.status == errSecSuccess else { return insert.status }
        return SecItemAdd(insert.attributes as CFDictionary, nil)
    }

    func delete(backend: MacKeychainBackend, service: String, account: String) -> OSStatus {
        SecItemDelete(MacKeychainQueries.matching(backend: backend, service: service, account: account) as CFDictionary)
    }
}
