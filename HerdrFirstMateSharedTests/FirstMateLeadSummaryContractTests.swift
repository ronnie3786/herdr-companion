import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("Additive lead metadata contract")
@MainActor
struct FirstMateLeadSummaryContractTests {
    @Test("Lead machine metadata is optional and cannot replace the feature identity")
    func optionalMachine() throws {
        let feature = FirstMateDemo.chatWindowLead().feature
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feature))
        var value: [String: Any] = ["feature": encoded, "unread": false, "working_on_reply": false]
        func decode() throws -> FirstMateLeadSummary {
            try JSONDecoder().decode(FirstMateLeadSummary.self, from: JSONSerialization.data(withJSONObject: value))
        }
        #expect(try decode().machine == nil)
        value["machine"] = NSNull()
        #expect(try decode().machine == nil)
        value["machine"] = ["id": "server-private-roster-id", "name": "Synthetic display name"]
        let lead = try decode()
        #expect(lead.machine?.id == "server-private-roster-id")
        #expect(lead.machine?.name == "Synthetic display name")
        #expect(lead.feature.id == feature.id && lead.feature.isLead)
        #expect(lead.peers == nil)
    }

    @Test("Journal capability remains per-store and changes only with the host's answer")
    func journalCapability() async {
        let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-journal-events-v1"]),
                                               features: [ChatFixtures.feature("synthetic-feature")])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        #expect(!store.journalEventSnapshotsSupported)
        await store.refresh()
        #expect(store.journalEventSnapshotsSupported)
        client.capabilities = .success(["first-mate-v1"])
        await store.refresh()
        #expect(!store.journalEventSnapshotsSupported)
    }
}
