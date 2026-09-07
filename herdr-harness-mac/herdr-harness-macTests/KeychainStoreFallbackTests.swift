import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@Suite("Secure credential persistence", .serialized)
struct KeychainStoreFallbackTests {
    @Test("A save never creates a plaintext UserDefaults fallback")
    func neverPersistsPlaintextFallback() {
        let account = "security-test-\(UUID().uuidString)"
        let fallbackKey = "herdr.keychainFallback.\(account)"
        defer { KeychainStore.removeValue(for: account) }

        let status = KeychainStore.set("test-only-token", for: account)

        #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
        if status == errSecSuccess {
            #expect(KeychainStore.value(for: account) == "test-only-token")
        } else {
            #expect(KeychainStore.value(for: account).isEmpty)
        }
        KeychainStore.set("", for: account)
        #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
        #expect(KeychainStore.value(for: account).isEmpty)
    }

    @Test("Legacy plaintext is removed only after secure migration succeeds")
    func legacyFallbackRequiresSuccessfulMigration() {
        let account = "security-migration-test-\(UUID().uuidString)"
        let fallbackKey = "herdr.keychainFallback.\(account)"
        UserDefaults.standard.set("legacy-test-token", forKey: fallbackKey)
        defer { KeychainStore.removeValue(for: account) }

        let recovered = KeychainStore.value(for: account)
        if recovered.isEmpty {
            #expect(UserDefaults.standard.string(forKey: fallbackKey) == "legacy-test-token")
        } else {
            #expect(recovered == "legacy-test-token")
            #expect(UserDefaults.standard.object(forKey: fallbackKey) == nil)
        }
    }
}
