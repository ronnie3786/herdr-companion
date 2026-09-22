import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate attention")
@MainActor
struct FirstMateAttentionTests {
    @Test("Only outstanding human-decision statuses count as attention")
    func statusMatrix() {
        for status in ["awaiting_direction", "blocked"] {
            #expect(FirstMateAttention.needsHumanDecision(status: status), "\(status) must wait on a human")
        }
        for status in [
            "ready", "coordinating", "running", "paused", "recovering",
            "completed", "complete", "cancelled", "failed", "error",
            "queued", "planned", "waiting_children", "unknown", "",
            "Awaiting_Direction", "awaiting_direction "
        ] {
            #expect(!FirstMateAttention.needsHumanDecision(status: status), "\(status) must not wait on a human")
        }
        #expect(FirstMateAttention.humanDecisionStatuses == Set(["awaiting_direction", "blocked"]))
    }

    @Test("A screenshot-equivalent fleet counts three waiting features and ignores working ones")
    func screenshotEquivalentFleet() {
        let hosts = [
            host(id: "alpha", features: [
                feature(id: "feature-one", status: "awaiting_direction"),
                feature(id: "feature-two", status: "awaiting_direction"),
                feature(id: "feature-three", status: "running"),
            ]),
            host(id: "beta", features: []),
            host(id: "gamma", features: [feature(id: "feature-four", status: "blocked")]),
        ]
        #expect(FirstMateAttention.count(hosts: hosts) == 3)
        #expect(FirstMateAttention.count(hosts: []) == 0)
    }

    @Test("Identical feature IDs stay distinct per host while duplicates collapse per host")
    func distinctAndDuplicateIdentities() {
        let alpha = host(id: "alpha", features: [
            feature(id: "shared", status: "awaiting_direction"),
            feature(id: "shared", status: "blocked"),
            feature(id: "shared", status: "running"),
        ])
        let beta = host(id: "beta", features: [feature(id: "shared", status: "awaiting_direction")])
        #expect(FirstMateAttention.count(hosts: [alpha, beta]) == 2)
        #expect(FirstMateAttention.count(hosts: [beta, alpha]) == 2)
    }

    @Test("A host that kept its last successful list still contributes after an error")
    func cachedFeaturesStillCount() {
        let cached = FirstMateFleetHost(
            machineID: "alpha",
            machineName: "Alpha Mac",
            features: [feature(id: "cached", status: "awaiting_direction")],
            isLoading: false,
            error: "Temporarily unavailable",
            unsupported: false,
            lastUpdated: .now
        )
        let freshEmpty = host(id: "beta", features: [])
        #expect(FirstMateAttention.count(hosts: [cached, freshEmpty]) == 1)
    }

    @Test("Archived features never contribute attention, even in an all-features response")
    func archivedFeaturesDoNotCount() {
        var awaiting = feature(id: "archived-awaiting", status: "awaiting_direction")
        awaiting.archivedAt = "2026-09-21T20:00:00Z"
        var blocked = feature(id: "archived-blocked", status: "blocked")
        blocked.archivedAt = "2026-09-21T20:01:00Z"
        let active = feature(id: "active-awaiting", status: "awaiting_direction")
        #expect(FirstMateAttention.count(hosts: [host(id: "alpha", features: [awaiting, blocked, active])]) == 1)
        #expect(FirstMateAttention.count(hosts: [host(id: "alpha", features: [awaiting, blocked])]) == 0)
    }

    private func host(id: String, features: [FirstMateFeature]) -> FirstMateFleetHost {
        FirstMateFleetHost(
            machineID: id,
            machineName: "\(id.capitalized) Mac",
            features: features,
            isLoading: false,
            error: nil,
            unsupported: false,
            lastUpdated: .now
        )
    }

    private func feature(id: String, status: String) -> FirstMateFeature {
        var feature = FirstMateDemo.newFeature(
            title: "Synthetic feature \(id)",
            goal: "A synthetic goal for \(id)",
            cwd: "/tmp/synthetic",
            id: id
        ).feature
        feature.status = status
        return feature
    }
}
