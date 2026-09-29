import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate Dock badge count")
@MainActor
struct FirstMateBadgeTests {
    @Test("Mixed hosts count fleet dots plus every needs-you feature on older hosts")
    func mixedHosts() {
        let fleet = ChatFixtures.host("alpha", entries: [
            ChatFixtures.entry("blocked", hud: .blocked),
            ChatFixtures.entry("turn-read", hud: .turn, unread: false),
            ChatFixtures.entry("ready", hud: .ready),
            ChatFixtures.entry("working", hud: .working),
            ChatFixtures.entry("idle", hud: .idle),
            ChatFixtures.entry("done", hud: .done),
            ChatFixtures.entry("unknown", hud: .unknown),
        ])
        let legacy = ChatFixtures.host("beta", features: [
            ChatFixtures.feature("b-blocked", status: "blocked"),
            ChatFixtures.feature("b-direction", status: "awaiting_direction"),
            ChatFixtures.feature("b-running", status: "running"),
            ChatFixtures.feature("b-recovering", status: "recovering"),
        ])
        #expect(FirstMateBadge.count(hosts: [fleet, legacy], readState: .init()) == 4)
        #expect(FirstMateBadge.count(hosts: [fleet], readState: .init()) == 2)
        #expect(FirstMateBadge.count(hosts: [], readState: .init()) == 0)
    }

    @Test("Duplicate records count once per machine and feature, and separately per machine")
    func duplicates() {
        let blocked = ChatFixtures.feature("shared", status: "blocked")
        let alpha = ChatFixtures.host("alpha", features: [blocked, blocked])
        let beta = ChatFixtures.host("beta", features: [blocked])
        #expect(FirstMateBadge.count(hosts: [alpha, beta], readState: .init()) == 2)
        // A fleet entry and its list record are one conversation.
        let fleet = ChatFixtures.host("gamma", features: [blocked], entries: [ChatFixtures.entry("shared", hud: .blocked)])
        #expect(FirstMateBadge.count(hosts: [fleet], readState: .init()) == 1)
    }

    @Test("Archived features never count, from the summary or the list")
    func archived() {
        let fleet = ChatFixtures.host("alpha", features: [ChatFixtures.feature("listed-archived", status: "blocked", archived: true)], entries: [
            ChatFixtures.entry("summary-archived", hud: .blocked, archived: true),
            ChatFixtures.entry("listed-archived", hud: .blocked),
        ])
        let legacy = ChatFixtures.host("beta", features: [ChatFixtures.feature("old", status: "awaiting_direction", archived: true)])
        #expect(FirstMateBadge.count(hosts: [fleet, legacy], readState: .init()) == 0)
    }

    @Test("A host without the fleet capability equals First Mate attention")
    func legacyEqualsAttention() {
        let statuses = ["blocked", "awaiting_direction", "running", "coordinating", "recovering", "ready", "paused",
                        "completed", "cancelled", "unverified", "brand_new"]
        let hosts = (0..<3).map { hostIndex in
            ChatFixtures.host("host-\(hostIndex)", features: statuses.enumerated().compactMap { index, status in
                (index + hostIndex) % 3 == 0 ? nil : ChatFixtures.feature("f\(index)", status: status, archived: index == 1 && hostIndex == 1)
            })
        }
        #expect(FirstMateBadge.count(hosts: hosts, readState: .init()) == FirstMateAttention.count(hosts: hosts))
        #expect(FirstMateAttention.count(hosts: hosts) > 0)
        // A summary the host keeps after losing the capability is ignored.
        var downgraded = ChatFixtures.host("downgraded", features: [ChatFixtures.feature("x", status: "running")],
                                           entries: [ChatFixtures.entry("x", hud: .blocked)])
        downgraded.supportsFleet = false
        #expect(FirstMateBadge.count(hosts: [downgraded], readState: .init()) == FirstMateAttention.count(hosts: [downgraded]))
    }

    @Test("A host whose refresh fails keeps its last successful count")
    func failedHostKeepsCount() async throws {
        let client = SyntheticChatFleetClient(
            features: [ChatFixtures.feature("waiting", status: "blocked")],
            fleet: [ChatFixtures.entry("waiting", hud: .blocked)]
        )
        let legacyClient = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1"]),
                                                    features: [ChatFixtures.feature("legacy", status: "awaiting_direction")])
        let index = FirstMateFleetIndex()
        let lifecycle = index.activate(sources: [ChatFixtures.source("alpha", client: client),
                                                 ChatFixtures.source("beta", client: legacyClient)], connectionGeneration: 1)
        await index.refresh(lifecycle: lifecycle)
        #expect(index.badgeCount == 2)

        client.features = .failure(.server(status: 502, message: "Offline"))
        legacyClient.features = .failure(.server(status: 502, message: "Offline"))
        await index.refresh(lifecycle: lifecycle)
        #expect(index.hosts.allSatisfy { $0.error != nil })
        #expect(index.badgeCount == 2)

        client.features = .success([ChatFixtures.feature("waiting", status: "blocked")])
        client.fleet = .failure(.server(status: 500, message: "Summary failed"))
        await index.refresh(lifecycle: lifecycle)
        #expect(index.badgeCount == 2, "A failed summary keeps the last one")
    }

    @Test("A chat read on this Mac leaves the count at once")
    func readStateClearsDot() {
        let entry = ChatFixtures.entry("blocked", hud: .blocked, latestFirstMate: "fmm_1")
        let host = ChatFixtures.host("alpha", entries: [entry])
        var readState = FirstMateReadState()
        readState.markRead(FirstMateFleetFeatureID(machineID: "alpha", featureID: "blocked"), messageID: "fmm_1")
        #expect(FirstMateBadge.count(hosts: [host], readState: .init()) == 1)
        #expect(FirstMateBadge.count(hosts: [host], readState: readState) == 0)
        // An override for another machine's feature with the same ID changes nothing.
        var other = FirstMateReadState()
        other.markRead(FirstMateFleetFeatureID(machineID: "beta", featureID: "blocked"), messageID: "fmm_1")
        #expect(FirstMateBadge.count(hosts: [host], readState: other) == 1)
    }
}
