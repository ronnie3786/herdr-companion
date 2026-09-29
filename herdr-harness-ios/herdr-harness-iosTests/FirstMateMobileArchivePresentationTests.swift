import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Phone archive presentation", .serialized)
@MainActor
struct FirstMateMobileArchivePresentationTests {
    @Test("Archive removal is optimistic, rolls back on failure, retains names and supports unarchive")
    func archiveLifecycle() async throws {
        let client = ArchivePresentationClient(), gate = ChatTestGate()
        await client.setGate(gate, fails: true)
        let machine = ChatFixtures.machine("alpha")
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "ArchivePresentation.\(UUID())")!)
        fleet.activate(sources: [.init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic"), client: client)], connectionGeneration: 1)
        await fleet.refreshAll()
        let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
        #expect(fleet.conversations.first?.name == "Custom receipts")
        let request = try #require(FirstMateMobileArchiveRequest.capture(target: target, fleet: fleet))
        let archiving = Task { await fleet.setArchived(target, archived: true, reason: .duplicate, expectedContext: request.context) }
        defer { Task { await gate.open() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.arrived)
        #expect(fleet.isArchiving(target) && fleet.conversations.isEmpty && fleet.badgeCount == 0)
        await gate.open()
        #expect(!(await archiving.value))
        #expect(!fleet.isArchiving(target) && fleet.conversations.count == 1 && fleet.badgeCount == 1)
        await client.setGate(nil, fails: false)
        #expect(await fleet.setArchived(target, archived: true, reason: .duplicate, expectedContext: request.store.operationContext))
        #expect(fleet.conversations.isEmpty && fleet.badgeCount == 0)
        fleet.setShowArchived(true)
        await fleet.refreshAll()
        let archived = try #require(fleet.archivedRows.first)
        let presentation = FirstMateMobileListPresentation.archived(archived, known: fleet.chat.knownPresentation(for: target))
        #expect(presentation.isArchived && presentation.name == "Custom receipts" && !presentation.showsDot)
        fleet.search = "custom"
        #expect(fleet.archivedConversations.map(\.name) == ["Custom receipts"], "Archive search must not prefilter away a retained user name")
        fleet.search = "unmatched"
        #expect(fleet.archivedConversations.isEmpty)
        fleet.search = ""
        #expect(await fleet.setArchived(target, archived: false, expectedContext: request.store.operationContext))
        #expect(fleet.archivedRows.isEmpty && fleet.conversations.count == 1)
        let calls = await client.calls
        #expect(calls.map(\.archived) == [true, true, false])
        #expect(calls.prefix(2).allSatisfy { $0.reason == .duplicate && $0.featureID == "feature" })
    }

    @Test("An archive sheet captures its store, not a replacement with the same machine ID")
    func capturedSheetOwner() async throws {
        let machine = ChatFixtures.machine("alpha"), client = ArchivePresentationClient()
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "ArchiveSheetOwner.\(UUID())")!)
        fleet.activate(sources: [.init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "old"), client: client)], connectionGeneration: 1)
        await fleet.refreshAll()
        let request = try #require(FirstMateMobileArchiveRequest.capture(target: .init(machineID: "alpha", featureID: "feature"), fleet: fleet))
        #expect(request.isCurrent(in: fleet))
        fleet.activate(sources: [.init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "new"), client: client)], connectionGeneration: 1)
        #expect(!request.isCurrent(in: fleet))
        #expect(!(await fleet.setArchived(request.target, archived: true, expectedContext: request.context)))
        #expect(await client.calls.isEmpty)
    }
}

private actor ArchivePresentationClient: FirstMateClient {
    struct Call: Sendable { let featureID: String; let archived: Bool; let reason: FirstMateArchiveReason? }
    private var feature = ChatFixtures.feature("feature", title: "Original receipt title", status: "blocked")
    private var gate: ChatTestGate?
    private var fails = false
    private(set) var calls: [Call] = []
    func setGate(_ gate: ChatTestGate?, fails: Bool) { self.gate = gate; self.fails = fails }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-fleet-v1", "first-mate-archive-v1"])
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: feature.isArchived ? [] : [feature]) }
    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        .init(ok: true, features: scope == .all || !feature.isArchived ? [feature] : [])
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        .init(features: feature.isArchived ? [] : [.init(featureID: feature.id, title: feature.title, label: "Custom receipts",
            emoji: "🧾", emojiSource: "user", status: feature.status, hudStatus: .blocked,
            latestFirstMateMessageID: "reply", unread: true, labelSource: "user")])
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { .init(feature: feature) }
    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot {
        calls.append(.init(featureID: featureID, archived: archived, reason: reason))
        await gate?.wait()
        if fails { throw APIError.server(status: 503, message: "Synthetic archive refusal") }
        feature.archivedAt = archived ? "2030-01-01T00:00:00Z" : nil
        feature.revision += 1
        return .init(feature: feature)
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
