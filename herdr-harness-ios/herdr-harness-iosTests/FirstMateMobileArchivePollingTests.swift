import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Mobile archive polling separation")
@MainActor
struct FirstMateMobileArchivePollingTests {
    @Test("Visible archive browsing uses the exact host's full list without changing the active badge")
    func archiveBrowser() async throws {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "ArchivePolling.\(UUID())")!)
        let client = MobileArchivePollingClient()
        let machine = ChatFixtures.machine("archive-owner")
        let source = FirstMateMobileFleetSource(machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic"), client: client)
        let driver = FirstMateFleetDriver(fleet: fleet)
        driver.fleetInterval = .milliseconds(20)
        driver.isFirstMateVisible = true
        let running = Task { await driver.observe(sources: [source], connectionGeneration: 1) }
        defer { running.cancel() }
        fleet.setShowArchived(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !fleet.archivedRows.contains(where: { $0.featureID == "archived" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fleet.archivedRows.map(\.featureID) == ["archived"])
        #expect(await client.allReads > 0)
        #expect(fleet.badgeCount == 1)
        driver.isFirstMateVisible = false
        let archiveReads = await client.allReads, activeReads = await client.activeReads
        try await Task.sleep(for: .milliseconds(80))
        #expect(await client.allReads == archiveReads)
        #expect(await client.activeReads > activeReads, "Other tabs still refresh the global active index")
        running.cancel(); await running.value
    }
}

private actor MobileArchivePollingClient: FirstMateClient {
    private(set) var allReads = 0
    private(set) var activeReads = 0
    private let active = ChatFixtures.feature("active", status: "blocked")
    private let archived = ChatFixtures.feature("archived", status: "blocked", archived: true)
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-archive-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        activeReads += 1
        return .init(ok: true, features: [active])
    }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        if scope == .all {
            allReads += 1
            return .init(ok: true, features: [active, archived])
        }
        return try await fetchFirstMateFeatures()
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        .init(feature: id == archived.id ? archived : active)
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
