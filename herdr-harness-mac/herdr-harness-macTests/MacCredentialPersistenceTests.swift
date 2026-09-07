import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@Suite("Mac secure credential backend migration")
struct MacCredentialPersistenceTests {
    @Test("The selected backend wins over an older retained credential")
    func currentValueWins() {
        let h = Harness()
        h.storage.items[.init(.login)] = "new-value"
        h.storage.items[.init(.dataProtection)] = "old-value"
        h.defaults.set("old-plaintext", forKey: h.fallbackKey)
        #expect(h.persistence().value(for: "account") == "new-value")
        #expect(h.storage.reads == [.init(.login)])
        #expect(h.defaults.object(forKey: h.fallbackKey) == nil)
        #expect(h.defaults.string(forKey: "unrelated-setting") == "preserved")
    }

    @Test("Accessible DP credentials migrate securely and remain available for rollback")
    func migrateDataProtection() {
        let h = Harness()
        h.storage.items[.init(.dataProtection)] = "old-value"
        #expect(h.persistence().value(for: "account") == "old-value")
        #expect(h.storage.items[.init(.login)] == "old-value")
        #expect(h.storage.items[.init(.dataProtection)] == "old-value")
        #expect(h.persistence().set("updated-value", for: "account") == errSecSuccess)
        #expect(h.persistence().value(for: "account") == "updated-value")
    }

    @Test("A private prior service can migrate from either backend")
    func migratePriorService() {
        let h = Harness()
        let source = Location(.dataProtection, service: "org.example.previous")
        h.storage.items[source] = "prior-service-value"
        #expect(h.persistence(legacy: "org.example.previous").value(for: "account") == "prior-service-value")
        #expect(h.storage.items[source] == "prior-service-value")
        #expect(h.storage.items[.init(.login)] == "prior-service-value")
    }

    @Test("A failed destination write preserves secure and plaintext migration sources")
    func failedMigrationKeepsSources() {
        let h = Harness()
        h.storage.items[.init(.dataProtection)] = "old-value"
        h.storage.writeError = errSecInteractionNotAllowed
        h.defaults.set("old-plaintext", forKey: h.fallbackKey)
        #expect(h.persistence().value(for: "account").isEmpty)
        #expect(h.storage.items[.init(.login)] == nil)
        #expect(h.storage.items[.init(.dataProtection)] == "old-value")
        #expect(h.defaults.string(forKey: h.fallbackKey) == "old-plaintext")
    }

    @Test("A locked or denied selected backend cannot fall through to another source")
    func lockedPrimaryFailsClosed() {
        for failure in [errSecInteractionNotAllowed, errSecAuthFailed] {
            let h = Harness()
            h.storage.readErrors[.init(.login)] = failure
            h.storage.items[.init(.dataProtection)] = "old-value"
            h.defaults.set("old-plaintext", forKey: h.fallbackKey)
            #expect(h.persistence().value(for: "account").isEmpty)
            #expect(h.storage.reads == [.init(.login)])
            #expect(h.storage.writes.isEmpty)
            #expect(h.defaults.string(forKey: h.fallbackKey) == "old-plaintext")
        }
    }

    @Test("A denied migration source cannot be bypassed by plaintext")
    func deniedSourceFailsClosed() {
        let h = Harness()
        h.storage.readErrors[.init(.dataProtection)] = errSecAuthFailed
        h.defaults.set("old-plaintext", forKey: h.fallbackKey)
        #expect(h.persistence().value(for: "account").isEmpty)
        #expect(h.storage.writes.isEmpty)
        #expect(h.defaults.string(forKey: h.fallbackKey) == "old-plaintext")
    }

    @Test("Unprovisioned DP does not prevent successful legacy-to-login migration")
    func migratePlaintextOnlyAfterSecureWrite() {
        let h = Harness()
        h.storage.readErrors[.init(.dataProtection)] = errSecMissingEntitlement
        h.defaults.set("legacy-test-value", forKey: h.fallbackKey)
        #expect(h.persistence().value(for: "account") == "legacy-test-value")
        #expect(h.storage.items[.init(.login)] == "legacy-test-value")
        #expect(h.defaults.object(forKey: h.fallbackKey) == nil)
    }

    @Test("Failed new writes never create plaintext fallback")
    func failedSaveNeverCreatesPlaintext() {
        let h = Harness()
        h.storage.writeError = errSecInteractionNotAllowed
        #expect(h.persistence().set("new-value", for: "account") == errSecInteractionNotAllowed)
        #expect(h.defaults.object(forKey: h.fallbackKey) == nil)
        #expect(h.storage.items.isEmpty)
    }

    @Test("Explicit DP configuration never silently downgrades on missing entitlement")
    func explicitDataProtectionRemainsExplicit() {
        let h = Harness()
        h.storage.readErrors[.init(.dataProtection)] = errSecMissingEntitlement
        h.storage.items[.init(.login)] = "existing-login-value"
        #expect(h.persistence(backend: .dataProtection).value(for: "account").isEmpty)
        #expect(h.storage.reads == [.init(.dataProtection)])
        #expect(h.storage.writes.isEmpty)
    }

    @Test("Deletion prevents inaccessible retained sources from restoring after a backend change")
    func deletionDoesNotResurrectCredentials() {
        let h = Harness()
        h.storage.items[.init(.login)] = "new-value"
        h.storage.items[.init(.dataProtection)] = "old-value"
        h.storage.deleteErrors[.init(.dataProtection)] = errSecMissingEntitlement
        #expect(h.persistence().set("", for: "account") == errSecSuccess)
        #expect(h.storage.items[.init(.dataProtection)] == "old-value")
        #expect(h.persistence().value(for: "account").isEmpty)
        #expect(h.persistence(backend: .dataProtection).value(for: "account").isEmpty)
        #expect(h.persistence().set("replacement", for: "account") == errSecSuccess)
        #expect(h.persistence().value(for: "account") == "replacement")
    }

    @Test("A failed primary delete preserves retryable state")
    func failedDeletePreservesState() {
        let h = Harness()
        h.storage.items[.init(.login)] = "existing-value"
        h.storage.deleteErrors[.init(.login)] = errSecInteractionNotAllowed
        h.defaults.set("legacy-test-value", forKey: h.fallbackKey)
        #expect(h.persistence().set("", for: "account") == errSecInteractionNotAllowed)
        #expect(h.defaults.string(forKey: h.fallbackKey) == "legacy-test-value")
        #expect(h.persistence().value(for: "account") == "existing-value")
    }

    @Test("Each backend uses its own security attributes")
    func backendSecurityAttributes() {
        for backend in [MacKeychainBackend.login, .dataProtection] {
            let query = MacKeychainQueries.matching(backend: backend, service: "org.example", account: "probe")
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == (backend == .dataProtection))
            let insertion = MacKeychainQueries.insertion(query, data: Data("synthetic".utf8), backend: backend)
            #expect(insertion.status == errSecSuccess)
            #expect((insertion.attributes[kSecAttrAccess as String] != nil) == (backend == .login))
            #expect((insertion.attributes[kSecAttrAccessible as String] != nil) == (backend == .dataProtection))
        }
    }

    private struct Location: Hashable {
        let backend: MacKeychainBackend
        let service: String
        let account: String
        init(_ backend: MacKeychainBackend, service: String = "org.example.current", account: String = "account") {
            self.backend = backend; self.service = service; self.account = account
        }
    }

    private final class Harness {
        let suite = "MacCredentialPersistenceTests." + UUID().uuidString
        let defaults: UserDefaults
        let storage = Storage()
        let fallbackKey = "herdr.keychainFallback.account"
        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("preserved", forKey: "unrelated-setting")
        }
        deinit { defaults.removePersistentDomain(forName: suite) }
        func persistence(backend: MacKeychainBackend = .login, legacy: String? = nil) -> MacCredentialPersistence {
            MacCredentialPersistence(backend: backend, service: "org.example.current", legacyService: legacy, defaults: defaults, storage: storage)
        }
    }

    private final class Storage: MacKeychainStorage {
        var items: [Location: String] = [:]
        var readErrors: [Location: OSStatus] = [:]
        var deleteErrors: [Location: OSStatus] = [:]
        var writeError: OSStatus?
        var reads: [Location] = []
        var writes: [Location] = []
        func read(backend: MacKeychainBackend, service: String, account: String) -> MacKeychainRead {
            let location = Location(backend, service: service, account: account)
            reads.append(location)
            if let error = readErrors[location] { return MacKeychainRead(status: error, value: nil) }
            guard let value = items[location] else { return MacKeychainRead(status: errSecItemNotFound, value: nil) }
            return MacKeychainRead(status: errSecSuccess, value: value)
        }
        func write(_ value: String, backend: MacKeychainBackend, service: String, account: String) -> OSStatus {
            let location = Location(backend, service: service, account: account)
            writes.append(location)
            if let writeError { return writeError }
            items[location] = value
            return errSecSuccess
        }
        func delete(backend: MacKeychainBackend, service: String, account: String) -> OSStatus {
            let location = Location(backend, service: service, account: account)
            if let error = deleteErrors[location] { return error }
            return items.removeValue(forKey: location) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
