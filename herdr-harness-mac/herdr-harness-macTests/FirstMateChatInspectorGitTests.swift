import Testing
@testable import herdr_harness_mac

@Suite("First Mate chat inspector Git routing")
@MainActor
struct FirstMateChatInspectorGitTests {
    @Test("A feature opens its owning machine and feature without pinning a checkout or commit")
    func featureTarget() throws {
        let identity = FirstMateFleetFeatureID(machineID: "machine-a", featureID: "feature")
        let target = try #require(FirstMateChatInspectorColumn.gitTarget(for: .feature(identity)))
        #expect(target.machineID == "machine-a")
        #expect(target.featureID == "feature")
        #expect(target.workspaceID == nil)
        #expect(target.commitSHA == nil)
    }

    @Test("My First Mate has no feature Git target")
    func leadHasNoTarget() {
        #expect(FirstMateChatInspectorColumn.gitTarget(for: .lead) == nil)
    }

    @Test("Reopening a feature keeps its window identity while other features get their own")
    func featureWindowIdentity() throws {
        let first = FirstMateFleetFeatureID(machineID: "machine-a", featureID: "feature-a")
        let second = FirstMateFleetFeatureID(machineID: "machine-a", featureID: "feature-b")
        let firstTarget = try #require(FirstMateChatInspectorColumn.gitTarget(for: .feature(first)))
        let reopened = try #require(FirstMateChatInspectorColumn.gitTarget(for: .feature(first)))
        let secondTarget = try #require(FirstMateChatInspectorColumn.gitTarget(for: .feature(second)))
        #expect(firstTarget == reopened)
        #expect(firstTarget.id != secondTarget.id)
    }
}
