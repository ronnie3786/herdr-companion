import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate HUD delivery")
@MainActor
struct FirstMateHudDeliveryTests {
    private func client() -> SyntheticChatFleetClient {
        var feature = ChatFixtures.feature("fmf_voice_lead", status: "ready")
        feature.kind = "lead"
        let client = SyntheticChatFleetClient(capabilities: .success(FirstMateLeadTests.leadCapabilities))
        client.lead = .init(feature: feature, unread: false, workingOnReply: false, latestMessage: nil)
        client.snapshots = [feature.id: FirstMateSnapshot(feature: feature)]
        return client
    }

    private func delivery(_ client: SyntheticChatFleetClient, featureID: String? = nil,
                          current: @escaping () -> Bool = { true }) -> FirstMateHudDelivery {
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        return FirstMateHudDelivery(transcript: "What needs my attention?", payload: "Synthetic dictated payload",
                                    destinationLabel: "First Mate on Synthetic Mac", store: store,
                                    featureID: featureID, connectionIsCurrent: current)
    }

    @Test("Connection refusal while opening the lead keeps the transcript and allows explicit retry")
    func failedOpen() async throws {
        let client = client()
        client.beforeEnsure = { throw URLError(.cannotConnectToHost) }
        let pending = delivery(client)
        #expect(!(await pending.send()))
        #expect(pending.transcript == "What needs my attention?")
        #expect(pending.error?.contains("Could not open First Mate on Synthetic Mac") == true)
        #expect(client.sent.isEmpty)
        #expect(!pending.isSending && !pending.isAccepted)
        client.beforeEnsure = nil
        #expect(client.sent.isEmpty, "Recovery never sends automatically")
        #expect(await pending.send())
        #expect(client.sent.map(\.text) == ["Synthetic dictated payload"])
        #expect(pending.isAccepted && pending.error == nil)
        #expect(!(await pending.send()))
        #expect(client.sent.count == 1, "An accepted message is never replayed")
    }

    @Test("A lost send response retries the same request, payload, and lead context")
    func sameReceiptOnRetry() async {
        let client = client()
        client.beforeSend = { throw URLError(.networkConnectionLost) }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let firstContext = FirstMateLeadContext(machines: [.init(name: "Synthetic peer", features: [])])
        store.leadContextProvider = { firstContext }
        let pending = FirstMateHudDelivery(transcript: "My words", payload: "My words", destinationLabel: "Synthetic lead",
                                            store: store, connectionIsCurrent: { true })
        #expect(!(await pending.send()))
        #expect(pending.error?.contains("Delivery could not be confirmed") == true)
        let originalRequest = client.sentRequestIDs.first
        client.beforeSend = nil
        store.leadContextProvider = { nil }
        #expect(await pending.send())
        #expect(client.sentRequestIDs == [originalRequest, originalRequest].compactMap { $0 })
        #expect(client.sentContexts == [firstContext, firstContext])
        #expect(client.sent.map(\.featureID) == ["fmf_voice_lead", "fmf_voice_lead"])
        #expect(client.sent.map(\.text) == ["My words", "My words"])
    }

    @Test("Discarding a failed HUD send also clears its local conversation error without resending")
    func discardClearsLocalFailure() async {
        let client = client()
        client.beforeSend = { throw URLError(.cannotConnectToHost) }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let pending = FirstMateHudDelivery(transcript: "My words", payload: "My words", destinationLabel: "Synthetic lead",
                                            store: store, connectionIsCurrent: { true })
        #expect(!(await pending.send()))
        #expect(store.sendFailure(for: "fmf_voice_lead") != nil)
        pending.discard()
        #expect(store.sendFailure(for: "fmf_voice_lead") == nil)
        #expect(client.sent.count == 1)
    }

    @Test("Two overlapping sends make one request")
    func duplicateSend() async throws {
        let client = client()
        let gate = ChatTestGate()
        client.beforeSend = { await gate.wait() }
        let pending = delivery(client)
        let first = Task { await pending.send() }
        try await ChatFixtures.waitUntil("send started") { pending.isSending && client.sent.count == 1 }
        #expect(!(await pending.send()))
        await gate.open()
        #expect(await first.value)
        #expect(client.sent.count == 1)
    }

    @Test("Changed connections never receive a retry or lose the words")
    func changedConnection() async {
        let client = client()
        client.beforeSend = { throw URLError(.cannotConnectToHost) }
        var current = true
        let pending = delivery(client, current: { current })
        #expect(!(await pending.send()))
        current = false
        client.beforeSend = nil
        #expect(!(await pending.send()))
        #expect(client.sent.count == 1)
        #expect(pending.error?.contains("connection changed") == true)
        #expect(!pending.transcript.isEmpty)
    }

    @Test("Connection changes while opening the lead stop the send before transport")
    func changedDuringOpen() async throws {
        let client = client()
        let gate = ChatTestGate()
        client.beforeEnsure = { await gate.wait() }
        var current = true
        let pending = delivery(client, current: { current })
        let task = Task { await pending.send() }
        try await ChatFixtures.waitUntil("opening lead") { client.ensureCalls == 1 }
        current = false
        await gate.open()
        #expect(!(await task.value))
        #expect(client.sent.isEmpty)
    }

    @Test("Cancellation before the message is submitted keeps the transcript without sending")
    func cancellation() async throws {
        let client = client()
        let gate = ChatTestGate()
        client.beforeEnsure = { await gate.wait() }
        let pending = delivery(client)
        let task = Task { await pending.send() }
        try await ChatFixtures.waitUntil("opening lead") { client.ensureCalls == 1 }
        task.cancel()
        await gate.open()
        #expect(!(await task.value))
        #expect(client.sent.isEmpty)
        #expect(!pending.transcript.isEmpty && pending.error != nil)
    }

    @Test("Feature replies also keep their original request ID, and never open the lead")
    func featureReply() async {
        let client = client()
        let feature = ChatFixtures.feature("fmf_target", status: "awaiting_direction")
        client.snapshots[feature.id] = FirstMateSnapshot(feature: feature)
        client.beforeSend = { throw URLError(.timedOut) }
        let pending = delivery(client, featureID: feature.id)
        #expect(!(await pending.send()))
        client.beforeSend = nil
        #expect(await pending.send())
        #expect(client.ensureCalls == 0)
        #expect(Set(client.sentRequestIDs).count == 1)
        #expect(client.sent.allSatisfy { $0.featureID == feature.id })
    }

    @Test("The recovery card renders a long transcript and connection error without clipping its actions")
    func recoveryCard() async throws {
        let client = client()
        client.beforeEnsure = { throw URLError(.cannotConnectToHost) }
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let pending = FirstMateHudDelivery(transcript: String(repeating: "A synthetic spoken sentence. ", count: 30),
            payload: "Synthetic prompt", destinationLabel: "First Mate on Synthetic Mac", store: store,
            connectionIsCurrent: { true })
        #expect(!(await pending.send()))
        let defaults = try #require(UserDefaults(suiteName: "FirstMateHudDeliveryTests.render.\(UUID().uuidString)"))
        let controller = FirstMateHudController(defaults: defaults, isInert: true)
        let result = try await HerdrRenderHarness.renderWindow("fmhud-kept-voice-message.png", size: .init(width: 340, height: 290)) {
            FirstMateHudDeliveryCard(controller: controller, delivery: pending)
        }
        result.expectSubstantial()
    }

    @Test("Fleet fallback never redirects an explicit retry to another machine's lead")
    func retryStaysOnOriginalMachine() async throws {
        let original = client()
        let fallback = client()
        original.beforeEnsure = { throw URLError(.cannotConnectToHost) }
        let model = ChatFixtures.model(demo: false)
        #expect(model.addMachine(name: "Alpha", urlString: "https://alpha.example.invalid", token: "synthetic-alpha"))
        #expect(model.addMachine(name: "Beta", urlString: "https://beta.example.invalid", token: "synthetic-beta"))
        let alpha = try #require(model.machines.first)
        let beta = try #require(model.machines.last)
        let shell = ChatFixtures.shell()
        shell.firstMateFleet.activate(sources: model.machines.map { machine in
            .init(machine: machine, configuration: model.firstMateConfiguration(machineID: machine.id)!,
                  client: machine.id == alpha.id ? original : fallback)
        }, connectionGeneration: model.connectionGeneration)
        await shell.firstMateFleet.refresh()
        let defaults = try #require(UserDefaults(suiteName: "FirstMateHudDeliveryTests.fallback.\(UUID().uuidString)"))
        let hud = FirstMateHudController(defaults: defaults, isInert: true, makeClient: {
            $0.baseURL.host == "alpha.example.invalid" ? original : fallback
        })
        hud.start(model: model, shell: shell)
        #expect(hud.leadMachineID == alpha.id)
        await hud.submit("What needs me?", byVoice: true)
        #expect(hud.delivery != nil)
        original.features = .failure(.server(status: 503, message: "Synthetic outage"))
        await shell.firstMateFleet.refresh()
        await shell.firstMateFleet.refresh()
        #expect(hud.leadMachineID == beta.id)
        original.beforeEnsure = nil
        await hud.retryDelivery()
        #expect(original.sent.count == 1)
        #expect(fallback.sent.isEmpty)
        #expect(hud.delivery == nil)
        hud.clearLatestLine()
    }

    @Test("A real HUD voice submission keeps a failed-open transcript, blocks overwrite, and recovers")
    func controllerRecovery() async throws {
        let client = client()
        client.beforeEnsure = { throw URLError(.cannotConnectToHost) }
        let model = ChatFixtures.model(demo: false)
        #expect(model.addMachine(name: "Synthetic Mac", urlString: "https://voice.example.invalid", token: "synthetic-token"))
        let machine = try #require(model.machines.first)
        let configuration = try #require(model.firstMateConfiguration(machineID: machine.id))
        let shell = ChatFixtures.shell()
        shell.firstMateFleet.activate(sources: [.init(machine: machine, configuration: configuration, client: client)],
                                      connectionGeneration: model.connectionGeneration)
        await shell.firstMateFleet.refresh()
        let defaults = try #require(UserDefaults(suiteName: "FirstMateHudDeliveryTests.\(UUID().uuidString)"))
        let hud = FirstMateHudController(defaults: defaults, isInert: true, makeClient: { _ in client })
        hud.start(model: model, shell: shell)
        await hud.submit("Check the build status.", byVoice: true)
        let kept = try #require(hud.delivery)
        #expect(kept.transcript == "Check the build status.")
        #expect(hud.visibleCard == .delivery)
        #expect(client.sent.isEmpty)
        hud.facePressBegan()
        #expect(hud.voicePhase == .idle, "A new recording cannot replace an unresolved send")
        hud.closeCards()
        hud.toggleChat()
        #expect(hud.visibleCard == .delivery, "Closing the card doesn't lose its recovery")
        client.beforeEnsure = nil
        await hud.retryDelivery()
        #expect(hud.delivery == nil)
        #expect(client.sent.count == 1)
        let sent = try #require(client.sent.first?.text)
        #expect(sent == PromptComposerSubmission.payload(draft: kept.transcript, attachments: [], quotes: [], references: [],
                                                         containsDictation: true))
        #expect(!hud.isSending)
        hud.closeCards()
        hud.clearLatestLine()
    }
}
