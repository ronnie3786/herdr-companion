import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herdr machine migration", .serialized)
@MainActor
struct HerdrMachineMigrationTests {
    private let credentials = TestCredentialStore()
    @Test("Legacy connection migrates once without losing state")
    func legacyMigration() throws {
        let suiteName = "herdr-machine-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacyToken = credentials.value(for: "api-token")
        var migratedID: String?
        defer {
            credentials.set(legacyToken, for: "api-token")
            if let migratedID { credentials.removeValue(for: "api-token.\(migratedID)") }
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        defaults.set("https://workstation.example.test:8444", forKey: "herdr.serverURL")
        defaults.set(["w1:p1"], forKey: "herdr.sidebar.starredChats")
        defaults.set(["w1"], forKey: "herdr.sidebar.collapsedWorkspaces")
        credentials.set("legacy-token", for: "api-token")
        let first = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        let machine = try #require(first.machines.count == 1 ? first.machines[0] : nil)
        migratedID = machine.id
        #expect(machine.name == "workstation")
        #expect(machine.urlString == "https://workstation.example.test:8444")
        #expect(credentials.value(for: "api-token.\(machine.id)") == "legacy-token")
        #expect(credentials.value(for: "api-token") == "legacy-token")
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["\(machine.id)|w1:p1"])
        #expect(defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") == ["\(machine.id)|w1"])
        let second = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        #expect(second.machines.count == 1)
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["\(machine.id)|w1:p1"])
        #expect(defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") == ["\(machine.id)|w1"])
    }

    @Test("Failed credential migration keeps legacy settings for a later retry")
    func failedMigrationIsRetryable() throws {
        let suiteName = "migration-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://desktop.example.test", forKey: "herdr.serverURL")
        defaults.set(["w1:p1"], forKey: "herdr.sidebar.starredChats")
        credentials.values["api-token"] = "legacy-test"
        credentials.saveStatus = -25308
        let first = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        #expect(first.machines.isEmpty)
        #expect(defaults.object(forKey: "herdr.machines") == nil)
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["w1:p1"])
        credentials.saveStatus = 0
        let second = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        let migrated = try #require(second.machines.first)
        #expect(credentials.value(for: "api-token.\(migrated.id)") == "legacy-test")
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["\(migrated.id)|w1:p1"])
    }

    @Test("Fresh install records an empty machine list")
    func freshMigration() {
        let suiteName = "herdr-machine-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        defaults.set(false, forKey: "herdr.completedSetup")
        let model = HerdrAppModel(credentials: credentials, arguments: [], userDefaults: defaults)
        #expect(model.machines.isEmpty)
        #expect(defaults.data(forKey: "herdr.machines") != nil)
        #expect(!model.hasCompletedSetup)
    }
}
