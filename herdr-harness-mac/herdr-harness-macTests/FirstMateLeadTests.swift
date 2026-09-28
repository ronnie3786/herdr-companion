import Foundation
import Testing
@testable import herdr_harness_mac

/// The lead First Mate (`first-mate-lead-v1`) on the Mac: which machine's lead
/// to talk to, opening and messaging it through a feature store, and the fleet
/// index's lead summary. Synthetic companions only.
@Suite("Lead First Mate")
@MainActor
struct FirstMateLeadTests {
    static let leadCapabilities = ["first-mate-v1", "first-mate-fleet-v1", "first-mate-lead-v1",
                                   "first-mate-context-v1", "first-mate-attachments-v1"]

    private func leadFeature(_ id: String = "fmf_synthetic_lead") -> FirstMateFeature {
        var feature = ChatFixtures.feature(id, title: "First Mate", status: "ready")
        feature.kind = "lead"
        return feature
    }

    private func summary(_ feature: FirstMateFeature, unread: Bool = false, latest: String? = nil) -> FirstMateLeadSummary {
        FirstMateLeadSummary(
            feature: feature, unread: unread, workingOnReply: false,
            latestMessage: latest.map { .init(id: "fmm_latest", role: "assistant", text: $0, createdAt: "2030-01-01T00:00:00Z") }
        )
    }

    private func leadSnapshot(_ feature: FirstMateFeature) -> FirstMateSnapshot {
        FirstMateSnapshot(feature: feature, messages: [
            FirstMateMessage(id: "fmm_ask", featureID: feature.id, role: "user", text: "What needs me?",
                             status: "done", createdAt: "2030-01-01T00:00:00Z", visibility: "conversation"),
            FirstMateMessage(id: "fmm_answer", featureID: feature.id, role: "assistant", text: "Nothing needs you right now.",
                             status: "done", createdAt: "2030-01-01T00:00:01Z", visibility: "conversation"),
        ])
    }

    @Test("The lead's machine is the saved choice, then the busiest, then this Mac, then roster order")
    func machineChoice() {
        #expect(FirstMateLeadMachine.choose(capable: ["alpha", "beta"], saved: "beta", local: "alpha",
                                            activeCounts: ["alpha": 9]) == "beta")
        #expect(FirstMateLeadMachine.choose(capable: ["alpha", "beta"], saved: "retired", local: "alpha",
                                            activeCounts: ["alpha": 1, "beta": 7]) == "beta")
        #expect(FirstMateLeadMachine.choose(capable: ["alpha", "beta"], saved: nil, local: "beta",
                                            activeCounts: ["alpha": 2, "beta": 2]) == "beta")
        #expect(FirstMateLeadMachine.choose(capable: ["alpha", "beta"], saved: nil, local: "gamma") == "alpha")
        #expect(FirstMateLeadMachine.choose(capable: [], saved: "alpha", local: "alpha") == nil)
    }

    @Test("The first choice is remembered only once every machine with a lead has loaded")
    func rememberChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "FirstMateLeadTests.\(UUID().uuidString)"))
        var alpha = ChatFixtures.host("alpha", entries: [])
        alpha.supportsLead = true
        var beta = ChatFixtures.host("beta", entries: [])
        beta.supportsLead = true
        beta.lastUpdated = nil
        FirstMateLeadMachine.remember("alpha", hosts: [alpha, beta], defaults: defaults)
        #expect(defaults.string(forKey: FirstMateLeadMachine.preferenceKey) == nil)
        beta.lastUpdated = Date(timeIntervalSince1970: 1_900_000_000)
        FirstMateLeadMachine.remember("alpha", hosts: [alpha, beta], defaults: defaults)
        #expect(defaults.string(forKey: FirstMateLeadMachine.preferenceKey) == "alpha")
        FirstMateLeadMachine.remember("beta", hosts: [alpha, beta], defaults: defaults)
        #expect(defaults.string(forKey: FirstMateLeadMachine.preferenceKey) == "alpha", "A valid choice is kept")
    }

    @Test("The lead hears about the other machines' active features, read-only")
    func otherMachinesContext() throws {
        let alpha = ChatFixtures.host("alpha", entries: [ChatFixtures.entry("alpha-one", hud: .blocked)])
        let beta = ChatFixtures.host("beta", entries: [
            ChatFixtures.entry("beta-blocked", hud: .blocked, step: 3),
            ChatFixtures.entry("beta-archived", hud: .working, archived: true),
        ])
        let context = try #require(FirstMateLeadMachine.context(hosts: [alpha, beta], excluding: "alpha"))
        #expect(context.machines.map(\.name) == ["Beta Mac"])
        let feature = try #require(context.machines.first?.features.first)
        #expect(context.machines.first?.features.count == 1)
        #expect(feature.status == "blocked")
        #expect(feature.step == "QA")
        #expect(FirstMateLeadMachine.context(hosts: [alpha], excluding: "alpha") == nil)
        #expect(FirstMateLeadMachine.activeCounts(hosts: [alpha, beta]) == ["alpha": 1, "beta": 1])
    }

    @Test("Opening the lead creates it, selects it, and keeps it out of the feature list")
    func storeOpensLead() async throws {
        let lead = leadFeature()
        let feature = ChatFixtures.feature("fmf_synthetic_feature")
        let client = SyntheticChatFleetClient(capabilities: .success(Self.leadCapabilities), features: [feature])
        client.lead = summary(lead)
        client.snapshots = [lead.id: leadSnapshot(lead)]
        let store = FirstMateStore()
        store.configure(client: client, demo: false)

        #expect(await store.openLead())
        #expect(store.leadFeatureID == lead.id)
        #expect(store.selectedFeatureID == lead.id)
        #expect(store.leadSupported && store.attachmentsSupported && store.contextSupported)
        #expect(store.leadSnapshot?.messages.count == 2)
        #expect(!store.features.contains { $0.id == lead.id })

        await store.refresh()
        #expect(store.selectedFeatureID == lead.id, "A refresh keeps the lead selected")
        #expect(store.features.map(\.id) == [feature.id])

        let elsewhere = FirstMateLeadContext(machines: [.init(name: "Beta Mac", features: [
            .init(label: "Calendar export", title: nil, status: "turn", step: nil, now: nil, unread: true, latest: nil),
        ])])
        store.leadContextProvider = { elsewhere }
        #expect(await store.sendPreparedMessage("Tell the feature to use CSV.", expectedContext: store.operationContext))
        #expect(client.sent.map(\.featureID) == [lead.id])
        #expect(client.sentContexts == [elsewhere], "Messages to the lead carry the other machines")
        #expect(client.ensureCalls == 1)

        client.snapshots[feature.id] = FirstMateSnapshot(feature: feature)
        store.select(feature.id)
        #expect(await store.sendPreparedMessage("A feature message.", expectedContext: store.operationContext))
        #expect(client.sentContexts.count == 1, "A feature's messages never carry it")
    }

    @Test("A companion without a lead fails to open one and changes nothing")
    func storeWithoutLead() async {
        let feature = ChatFixtures.feature("fmf_synthetic_feature")
        let client = SyntheticChatFleetClient(features: [feature])
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        let selected = store.selectedFeatureID
        #expect(!(await store.openLead()))
        #expect(store.leadFeatureID == nil)
        #expect(store.selectedFeatureID == selected)
        #expect(!store.leadSupported)
    }

    @Test("The fleet index learns which machines have a lead and polls its summary")
    func fleetIndexLead() async throws {
        let lead = leadFeature()
        let withLead = SyntheticChatFleetClient(capabilities: .success(Self.leadCapabilities))
        withLead.lead = summary(lead, unread: true, latest: "Receipt export needs your call.")
        let withoutLead = SyntheticChatFleetClient()
        let index = FirstMateFleetIndex()
        index.activate(sources: [ChatFixtures.source("alpha", client: withLead), ChatFixtures.source("beta", client: withoutLead)],
                       connectionGeneration: 1)
        await index.refresh()

        let alpha = try #require(index.hosts.first { $0.machineID == "alpha" })
        let beta = try #require(index.hosts.first { $0.machineID == "beta" })
        #expect(alpha.supportsLead)
        #expect(alpha.lead?.unread == true)
        #expect(alpha.lead?.latestMessage?.text == "Receipt export needs your call.")
        #expect(!beta.supportsLead)
        #expect(beta.lead == nil)
        #expect(withoutLead.leadCalls == 0)
        #expect(FirstMateLeadMachine.capable(hosts: index.hosts) == ["alpha"])

        await index.markLeadRead(machineID: "alpha", throughMessageID: "fmm_latest")
        #expect(withLead.reads.map(\.featureID) == [lead.id])
        #expect(index.hosts.first { $0.machineID == "alpha" }?.lead?.unread == false)
    }

    @Test("The lead's context line names it plainly and explains handoff and compaction")
    func contextPresentation() {
        var lead = leadFeature()
        lead.nativeSessionID = "native-lead"
        lead.coordinatorContext = FirstMateCoordinatorContext(nativeSessionID: "native-lead", status: .measured, tokens: 60_000,
                                                              contextWindow: 1_000_000, handoffTargetTokens: 150_000)
        let presentation = FirstMateCoordinatorContextPresentation(feature: lead, capabilityAvailable: true)
        #expect(presentation.compactLine.hasPrefix("Context 6%"))
        #expect(presentation.policy.contains("compacts"))
        #expect(presentation.pressure == "Managed handoff target 150,000 tokens")

        let feature = ChatFixtures.feature("fmf_synthetic_feature")
        #expect(FirstMateCoordinatorContextPresentation(feature: feature, capabilityAvailable: true).summary.hasPrefix("Coordinator context"))
    }

    @Test("The demo lead is a lead with a skimmed answer, never a feature")
    func demoLead() {
        let lead = FirstMateDemo.chatWindowLead(now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(lead.feature.isLead)
        #expect(lead.messages.last?.skim?.status == .ready)
        let store = FirstMateStore()
        store.configure(client: nil, demo: true, demoFeatures: FirstMateDemo.chatWindowFeatures() + [lead])
        #expect(store.leadSupported)
        #expect(store.leadFeatureID == lead.feature.id)
        #expect(!store.features.contains { $0.isLead })
    }

    @Test("Compact lead history groups a checkpoint before applying its row limit")
    func compactLeadCheckpoint() {
        var snapshot = leadSnapshot(leadFeature())
        snapshot.feature.status = "awaiting_direction"
        snapshot.feature.currentVisitID = "visit"
        snapshot.messages[1].metadata = .init(turnID: "fmm_ask", visitID: "visit", checkpoint: true)
        var closing = snapshot.messages[1]
        closing.id = "fmm_closing"
        closing.text = "A duplicate closing question"
        closing.metadata = .init(inReplyTo: "fmm_ask")
        snapshot.messages.append(closing)
        let recent = FirstMateTranscriptLayout.recentRows(for: snapshot.messages, limit: 1,
            pendingDecisionMessageID: snapshot.pendingDecisionMessageID, now: .now, calendar: .current)
        #expect(recent.map(\.id) == ["fmm_answer"])
        #expect(recent[0].additionalReplies == [closing])
        #expect(recent[0].isPendingDecision)
        #expect(recent[0].isFirstInGroup)
        #expect(FirstMateTranscriptLayout.recentRows(for: snapshot.messages, limit: 0, now: .now, calendar: .current).isEmpty)
    }
}
