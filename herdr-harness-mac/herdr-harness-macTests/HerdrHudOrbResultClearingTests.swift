import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD orb result clearing")
struct HerdrHudOrbResultClearingTests {
    @Test("Available files and links are all clearable in input order")
    func mixedResults() {
        let artifacts = [artifact(id: "link-1", kind: .link),
                         artifact(id: "file-1", kind: .file),
                         artifact(id: "link-2", kind: .link)]

        let clearable = HerdrHudOrbResultClearing.clearableArtifacts(artifacts) { _ in .available }

        #expect(clearable.map(\.id) == artifacts.map(\.id))
    }

    @Test("Opening, downloading, and just-opened results cannot be cleared")
    func skipsBusyAndOpened() {
        let artifacts = (1...5).map { artifact(id: "result-\($0)", kind: .link) }
        let phases: [String: AgentResultArtifactPhase] = [
            artifacts[0].id: .opening,
            artifacts[1].id: .downloading,
            artifacts[2].id: .opened,
            artifacts[3].id: .failed("Unavailable"),
            artifacts[4].id: .available,
        ]

        let clearable = HerdrHudOrbResultClearing.clearableArtifacts(artifacts) {
            phases[$0] ?? .available
        }

        #expect(clearable.map(\.id) == [artifacts[3].id, artifacts[4].id])
    }

    @Test("An empty orb has nothing to clear")
    func emptyResults() {
        #expect(HerdrHudOrbResultClearing.clearableArtifacts([]) { _ in .available }.isEmpty)
    }

    @Test("Results folded behind the overflow badge are also clearable")
    func includesOverflow() {
        let artifacts = (0..<(HerdrHudPlacement.maxVisibleResults + 2)).map {
            artifact(id: "result-\($0)", kind: .link)
        }

        let clearable = HerdrHudOrbResultClearing.clearableArtifacts(artifacts) { _ in .available }

        #expect(clearable.map(\.id) == artifacts.map(\.id))
        #expect(clearable.count > HerdrHudPlacement.maxVisibleResults)
    }

    @Test("The menu label leads with Clear all")
    func menuTitle() {
        #expect(HerdrHudOrbResultClearing.menuTitle.hasPrefix("Clear all"))
        #expect(HerdrHudOrbResultClearing.accessibilityActionName == "Clear all results")
    }

    private func artifact(id: String, kind: AgentResultArtifact.Kind) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: .agentRun,
            originID: "run-1",
            kind: kind,
            title: "Result",
            filename: kind == .file ? "result.txt" : nil,
            contentType: kind == .file ? "text/plain" : nil,
            byteSize: kind == .file ? 5 : nil,
            createdAt: "2026-09-02T20:00:00Z",
            downloadPath: kind == .file ? "/api/v1/result-artifacts/\(id)/content" : nil,
            url: kind == .link ? URL(string: "https://example.com/result") : nil
        ).stamped(machineID: "development")
    }
}
