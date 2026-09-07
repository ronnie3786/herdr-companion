import Foundation
import Security
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Signed app credential probe")
struct HerdrKeychainProbeTests {
    private let id = "00000000-0000-4000-8000-000000000001"

    @Test("Ordinary launches never access the probe store")
    func normalLaunch() {
        let store = ProbeStore()
        #expect(HerdrKeychainProbe.runIfRequested(arguments: ["Herdr"], store: store) == nil)
        #expect(store.accounts.isEmpty)
    }

    @Test("Invalid probe input cannot address a user credential")
    func invalidArguments() throws {
        let store = ProbeStore()
        for args in [
            ["Herdr", HerdrKeychainProbe.argument],
            ["Herdr", HerdrKeychainProbe.argument, "delete", "api-token"],
            ["Herdr", HerdrKeychainProbe.argument, "read", id, "extra"],
            ["Herdr", HerdrKeychainProbe.argument, "replace", id],
        ] {
            let report = try #require(HerdrKeychainProbe.runIfRequested(arguments: args, store: store))
            #expect(!report.ok)
            #expect(report.status == errSecParam)
        }
        #expect(store.accounts.isEmpty)
    }

    @Test("Separate invocations verify persistence and delete only their synthetic item")
    func persistentProbeAndCleanup() throws {
        let store = ProbeStore()
        store.items["api-token"] = Data("unrelated-test-credential".utf8)
        for operation in ["write", "read", "read", "delete"] {
            #expect(try run(operation, store: store).ok)
        }
        #expect(store.items == ["api-token": Data("unrelated-test-credential".utf8)])
        #expect(Set(store.accounts) == ["herdr.synthetic-keychain-probe." + id])
        #expect(try run("read", store: store).status == errSecItemNotFound)
        #expect(try run("delete", store: store).ok)
    }

    @Test("Existing probe items are never overwritten")
    func duplicateWriteFails() throws {
        let store = ProbeStore()
        #expect(try run("write", store: store).ok)
        let report = try run("write", store: store)
        #expect(!report.ok)
        #expect(report.status == errSecDuplicateItem)
    }

    @Test("A wrong stored value cannot pass verification or appear in diagnostic JSON")
    func wrongValueFailsWithoutDisclosure() throws {
        let store = ProbeStore()
        store.items["herdr.synthetic-keychain-probe." + id] = Data("unrelated-private-value".utf8)
        let report = try run("read", store: store)
        #expect(!report.ok)
        #expect(!report.verified)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("unrelated-private-value"))
        #expect(!json.contains(id))
        #expect(!json.contains("herdr.synthetic-keychain-probe"))
    }

    @Test("Keychain errors remain failures without fallback or cleanup of other items")
    func failuresRemainFailures() throws {
        let store = ProbeStore()
        store.error = errSecMissingEntitlement
        for operation in ["write", "read", "delete"] {
            let report = try run(operation, store: store)
            #expect(!report.ok)
            #expect(report.status == errSecMissingEntitlement)
        }
        #expect(store.items.isEmpty)
    }

    @Test("Probe queries use the production selected Keychain and service")
    func productionQuery() {
        let query = KeychainStore.secureItemQuery(for: "herdr.synthetic-keychain-probe." + id)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == (HerdrAppIdentity.keychainBackend == .dataProtection))
        #expect(query[kSecAttrService as String] as? String == HerdrAppIdentity.keychainService)
        #expect(query[kSecAttrAccount as String] as? String == "herdr.synthetic-keychain-probe." + id)
    }

    private func run(_ operation: String, store: ProbeStore) throws -> HerdrKeychainProbe.Report {
        try #require(HerdrKeychainProbe.runIfRequested(arguments: ["Herdr", HerdrKeychainProbe.argument, operation, id], store: store))
    }

    private final class ProbeStore: HerdrKeychainProbeStore {
        var items: [String: Data] = [:]
        var accounts: [String] = []
        var error: OSStatus?

        func create(_ data: Data, account: String) -> OSStatus {
            accounts.append(account)
            if let error { return error }
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }
        func read(account: String) -> (status: OSStatus, data: Data?) {
            accounts.append(account)
            if let error { return (error, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
        func delete(account: String) -> OSStatus {
            accounts.append(account)
            if let error { return error }
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
