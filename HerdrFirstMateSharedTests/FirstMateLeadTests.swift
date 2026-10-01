import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

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

    private func choose(_ capable: [String], offline: Set<String> = [], pinned: String? = nil, local: String? = nil,
                        conversation: Set<String> = [], counts: [String: Int] = [:]) -> FirstMateLeadMachine.Choice {
        FirstMateLeadMachine.choose(capable: capable, offline: offline, pinned: pinned, local: local,
                                    withConversation: conversation, activeCounts: counts)
    }

    @Test("The lead lives on the pinned machine, else this Mac's, else where a conversation is, else the busiest")
    func machineChoice() {
        // This Mac's machine wins over a busier one: its lead reaches the others itself.
        #expect(choose(["work", "devbox"], local: "work", counts: ["work": 1, "devbox": 7]).current == "work")
        #expect(choose(["work", "devbox"], pinned: "devbox", local: "work").current == "devbox")
        #expect(choose(["work", "devbox"], pinned: "retired", local: "work").current == "work")
        #expect(choose(["alpha", "beta"], local: "gamma", conversation: ["alpha"], counts: ["beta": 5]).current == "alpha")
        #expect(choose(["alpha", "beta"], counts: ["alpha": 1, "beta": 7]).current == "beta")
        #expect(choose(["alpha", "beta"]).current == "alpha")
        #expect(choose([], pinned: "alpha", local: "alpha") == .init(current: nil, preferred: nil))
    }

    @Test("While the lead's machine is offline another machine's lead stands in, and it returns after")
    func machineFallback() {
        let down = choose(["work", "devbox"], offline: ["work"], local: "work", counts: ["devbox": 7])
        #expect(down == .init(current: "devbox", preferred: "work"))
        #expect(down.isFallback)
        let pinnedDown = choose(["work", "devbox", "studio"], offline: ["devbox"], pinned: "devbox", local: "work")
        #expect(pinnedDown == .init(current: "work", preferred: "devbox"))
        let allDown = choose(["work", "devbox"], offline: ["work", "devbox"], local: "work")
        #expect(allDown == .init(current: "work", preferred: "work"), "With nothing reachable it stays put")
        #expect(!allDown.isFallback)
        #expect(choose(["work", "devbox"], local: "work") == .init(current: "work", preferred: "work"))
    }

    @Test("This Mac's machine is home only once its lead can reach the others")
    func homeNeedsPeers() {
        var work = ChatFixtures.host("work", entries: [])
        work.supportsLead = true
        #expect(FirstMateLeadMachine.home("work", hosts: [work]) == nil, "An older companion keeps the lead where it was")
        work.supportsLeadPeers = true
        #expect(FirstMateLeadMachine.home("work", hosts: [work]) == "work")
        #expect(FirstMateLeadMachine.home(nil, hosts: [work]) == nil)
        #expect(FirstMateLeadMachine.home("studio", hosts: [work]) == nil)
    }

    @Test("A machine counts as offline only after more than one failed poll")
    func offlineAfterFailedPolls() {
        var work = ChatFixtures.host("work", entries: [])
        work.failedPolls = 1
        #expect(FirstMateLeadMachine.offline(hosts: [work]).isEmpty)
        work.failedPolls = 2
        #expect(FirstMateLeadMachine.offline(hosts: [work]) == ["work"])
    }


    @Test("The lead hears about machines it does not reach itself, read-only, offline ones marked")
    func otherMachinesContext() throws {
        let alpha = ChatFixtures.host("alpha", entries: [ChatFixtures.entry("alpha-one", hud: .blocked)])
        let beta = ChatFixtures.host("beta", entries: [
            ChatFixtures.entry("beta-blocked", hud: .blocked, step: 3),
            ChatFixtures.entry("beta-archived", hud: .working, archived: true),
        ])
        let context = try #require(FirstMateLeadMachine.context(hosts: [alpha, beta], excluding: "alpha"))
        #expect(context.machines.map(\.name) == ["Beta Mac"])
        #expect(context.machines.first?.offline == nil)
        let feature = try #require(context.machines.first?.features.first)
        #expect(context.machines.first?.features.count == 1)
        #expect(feature.status == "blocked")
        #expect(feature.step == "QA")
        #expect(FirstMateLeadMachine.context(hosts: [alpha], excluding: "alpha") == nil)
        #expect(FirstMateLeadMachine.activeCounts(hosts: [alpha, beta]) == ["alpha": 1, "beta": 1])

        // Its companion reaches beta itself (matched by origin), so beta is left out.
        let machines = [HerdrMachine(id: "alpha", name: "Alpha Mac", urlString: "http://127.0.0.1:9092"),
                        HerdrMachine(id: "beta", name: "Beta Mac", urlString: "https://beta.example.invalid:8461")]
        var reaching = alpha
        reaching.lead = FirstMateLeadSummary(feature: leadFeature(), unread: false, workingOnReply: false, latestMessage: nil,
                                             peers: [.init(id: "devbox", name: "Beta", url: "https://beta.example.invalid:8461/")])
        #expect(FirstMateLeadMachine.reached(by: reaching.lead, machines: machines) == ["beta"])
        #expect(FirstMateLeadMachine.context(hosts: [reaching, beta], machines: machines, excluding: "alpha") == nil)
        // A machine this Mac cannot reach is sent as last seen, marked offline.
        var offline = beta
        offline.failedPolls = 2
        let marked = try #require(FirstMateLeadMachine.context(hosts: [alpha, offline], machines: machines, excluding: "alpha"))
        #expect(marked.machines.first?.offline == true)
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
        #expect(!alpha.supportsLeadPeers)
        #expect(alpha.lead?.unread == true)
        #expect(alpha.lead?.latestMessage?.text == "Receipt export needs your call.")
        #expect(!beta.supportsLead)
        #expect(beta.lead == nil)
        #expect(withoutLead.leadCalls == 0)
        #expect(FirstMateLeadMachine.capable(hosts: index.hosts) == ["alpha"])

        await index.markLeadRead(machineID: "alpha", throughMessageID: "fmm_latest")
        #expect(withLead.reads.map(\.featureID) == [lead.id])
        #expect(index.hosts.first { $0.machineID == "alpha" }?.lead?.unread == false)

        // Failed polls count up to a cap, keep the last summary, and reset on an answer.
        withLead.features = .failure(.server(status: 503, message: "Synthetic outage"))
        for _ in 0..<5 { await index.refresh() }
        let down = try #require(index.hosts.first { $0.machineID == "alpha" })
        #expect(down.failedPolls == FirstMateFleetIndex.failedPollsCap)
        #expect(down.lead?.feature.id == lead.id)
        #expect(FirstMateLeadMachine.offline(hosts: index.hosts) == ["alpha"])
        withLead.features = .success([])
        await index.refresh()
        #expect(index.hosts.first { $0.machineID == "alpha" }?.failedPolls == 0)

        // A companion whose lead reaches other machines says so.
        let withPeers = SyntheticChatFleetClient(capabilities: .success(Self.leadCapabilities + ["first-mate-lead-peers-v1"]))
        let peersIndex = FirstMateFleetIndex()
        peersIndex.activate(sources: [ChatFixtures.source("gamma", client: withPeers)], connectionGeneration: 1)
        await peersIndex.refresh()
        #expect(peersIndex.hosts.first?.supportsLeadPeers == true)
    }

    @Test("The lead's context line names it plainly and explains handoff and compaction")
    func contextPresentation() {
        var lead = leadFeature()
        lead.nativeSessionID = "native-lead"
        lead.coordinatorContext = FirstMateCoordinatorContext(nativeSessionID: "native-lead", status: .measured, tokens: 60_000,
                                                              contextWindow: 1_000_000, handoffTargetTokens: 150_000)
        let presentation = FirstMateCoordinatorContextPresentation(feature: lead, capabilityAvailable: true)
        #expect(presentation.compactLine.hasPrefix("Context 6%"))
        #expect(presentation.policy.contains("Pi compaction is cancelled only for this managed session"))
        #expect(presentation.pressure == "Managed handoff target 150,000 tokens")

        let feature = ChatFixtures.feature("fmf_synthetic_feature")
        #expect(FirstMateCoordinatorContextPresentation(feature: feature, capabilityAvailable: true).summary.hasPrefix("Second Mate context"))
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
