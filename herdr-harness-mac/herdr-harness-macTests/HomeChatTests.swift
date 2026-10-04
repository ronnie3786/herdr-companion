import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Home lead chat and transfer", .serialized)
@MainActor
struct HomeChatTests {
    @Test("Pop-out appends once and moves uploaded attachments and context to the exact lead")
    func appendAndConsumeOnce() async throws {
        let fixture = Fixture()
        let context = HomeChatContext(title: "Review needs you", summary: "A prepared review is ready to open.")
        fixture.controller.open(context: context, draft: "Please explain this review.")
        await fixture.controller.prepare()
        let featureID = try #require(fixture.controller.owner?.featureID)
        let attachment = attachment(featureID: featureID)
        fixture.controller.store.composerDrafts.setAttachments([attachment], for: featureID)
        let session = fixture.window()
        let destination = try #require(session.store(for: "alpha"))
        #expect(await destination.openLead())
        destination.setComposerDraft("Existing window draft", for: destination.operationContext)
        #expect(fixture.controller.requestTransfer())
        let requestID = try #require(fixture.controller.pendingTransfer?.id)
        #expect(await session.consumeHomeTransfer(from: fixture.controller))
        #expect(destination.draft == "Existing window draft\n\nPlease explain this review.")
        #expect(destination.composerDrafts.attachments(for: featureID) == [attachment])
        #expect(session.homeContexts == [context])
        #expect(session.homeLeadOwner?.target.machineID == "alpha")
        #expect(session.homeLeadOwner?.featureID == featureID)
        #expect(fixture.controller.pendingTransfer == nil)
        #expect(fixture.controller.draft.isEmpty)
        #expect(!fixture.controller.isPresented)
        #expect(fixture.controller.store.composerDrafts.attachments(for: featureID).isEmpty)
        #expect(!(await session.consumeHomeTransfer(from: fixture.controller)))
        #expect(destination.draft == "Existing window draft\n\nPlease explain this review.")
        #expect(session.homeContexts.map(\.id) == [context.id])
        #expect(requestID != context.id)
    }

    @Test("A changed draft and newly staged material survive delayed transfer acknowledgement")
    func preservesNewerMaterial() async throws {
        let fixture = Fixture()
        fixture.controller.open(context: .init(title: "Old context", summary: "Original evidence"), draft: "Original draft")
        await fixture.controller.prepare()
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        let task = Task { await session.consumeHomeTransfer(from: fixture.controller) }
        try await waitFor(gate)
        fixture.controller.setDraft("A newer draft")
        let newContext = HomeChatContext(title: "New context", summary: "New evidence")
        fixture.controller.open(context: newContext)
        let featureID = try #require(fixture.controller.owner?.featureID)
        let newAttachment = attachment(featureID: featureID)
        fixture.controller.store.composerDrafts.setAttachments([newAttachment], for: featureID)
        await gate.open()
        #expect(await task.value)
        #expect(session.leadStore?.draft == "Original draft")
        #expect(fixture.controller.draft == "A newer draft")
        #expect(fixture.controller.contexts == [newContext])
        #expect(fixture.controller.store.composerDrafts.attachments(for: featureID) == [newAttachment])
    }

    @Test("An identical text replacement is a newer draft and is never cleared by an ack")
    func preservesIdenticalReplacement() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Same text")
        await fixture.controller.prepare()
        #expect(fixture.controller.requestTransfer())
        let transfer = try #require(fixture.controller.pendingTransfer)
        fixture.controller.setDraft("Same text")
        fixture.controller.acknowledgeTransfer(transfer)
        #expect(fixture.controller.draft == "Same text")
    }

    @Test("Changing a connection during lead hydration rejects the transfer without a fallback")
    func rejectsReconfiguredOwner() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Stay on alpha")
        await fixture.controller.prepare()
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        let task = Task { await session.consumeHomeTransfer(from: fixture.controller) }
        try await waitFor(gate)
        fixture.model.connectionGeneration += 1
        await gate.open()
        #expect(!(await task.value))
        #expect(fixture.controller.draft == "Stay on alpha")
        #expect(fixture.controller.isPresented)
        #expect(fixture.controller.owner?.target.machineID == "alpha")
        #expect(fixture.controller.pendingTransfer == nil)
        #expect(fixture.controller.availabilityMessage?.contains("changed") == true)
    }

    @Test("An idle Home chat reopens its lead after the connection changes")
    func idleChatRecoversAfterReconnect() async {
        let fixture = Fixture()
        fixture.controller.open()
        await fixture.controller.prepare()
        #expect(fixture.controller.owner?.target.generation == fixture.model.connectionGeneration)
        fixture.controller.dismiss()
        fixture.model.connectionGeneration += 1
        fixture.controller.open()
        await fixture.controller.prepare()
        #expect(fixture.controller.owner?.target.generation == fixture.model.connectionGeneration)
        #expect(fixture.controller.isOwnerCurrent)
        #expect(fixture.controller.availabilityMessage == nil)
    }

    @Test("An open already in flight finishes before the chat re-resolves its lead")
    func releaseWaitsForOpen() async throws {
        let fixture = Fixture()
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        fixture.controller.open()
        let first = Task { await fixture.controller.prepare() }
        try await waitFor(gate)
        fixture.model.connectionGeneration += 1
        await fixture.controller.prepare()
        #expect(fixture.controller.isOpening, "Try again during an open keeps that open's lifecycle")
        fixture.client.beforeEnsure = nil
        await gate.open()
        await first.value
        #expect(!fixture.controller.isOpening)
        await fixture.controller.prepare()
        #expect(fixture.controller.owner?.target.generation == fixture.model.connectionGeneration)
        #expect(fixture.controller.availabilityMessage == nil)
    }

    @Test("A Home chat holding a draft keeps its lead when the connection changes")
    func draftKeepsItsLead() async {
        let fixture = Fixture()
        fixture.controller.open(draft: "Stay with this lead")
        await fixture.controller.prepare()
        let original = fixture.controller.owner
        fixture.model.connectionGeneration += 1
        await fixture.controller.prepare()
        #expect(fixture.controller.owner == original)
        #expect(fixture.controller.draft == "Stay with this lead")
        #expect(fixture.controller.availabilityMessage?.contains("changed") == true)
    }

    @Test("An idle Home chat follows the lead to another machine")
    func idleChatFollowsLead() async {
        let fixture = Fixture()
        let lead = LeadChoice()
        let configuration = fixture.configuration
        let transport = fixture.client
        let controller = HomeChatController(model: fixture.model, shell: fixture.shell,
                                            configuration: { _ in configuration }, makeClient: { _ in transport },
                                            chooseMachine: { lead.machineID })
        controller.open()
        await controller.prepare()
        #expect(controller.owner?.target.machineID == "alpha")
        controller.dismiss()
        lead.machineID = "beta"
        controller.open()
        await controller.prepare()
        #expect(controller.owner?.target.machineID == "beta")
    }

    @Test("A different lead on the same machine cannot consume a transfer")
    func rejectsWrongLead() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "For the original lead")
        await fixture.controller.prepare()
        let wrongClient = Fixture.client(featureID: "another-lead")
        let session = fixture.window(client: wrongClient)
        #expect(fixture.controller.requestTransfer())
        #expect(!(await session.consumeHomeTransfer(from: fixture.controller)))
        #expect(fixture.controller.draft == "For the original lead")
        #expect(fixture.controller.owner?.featureID == "alpha-lead")
        #expect(session.homeLeadOwner == nil)
    }

    @Test("An unavailable transferred owner remains explicit instead of selecting another lead")
    func keepsExactWindowOwner() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Exact owner")
        await fixture.controller.prepare()
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        #expect(await session.consumeHomeTransfer(from: fixture.controller))
        fixture.model.machines.removeAll { $0.id == "alpha" }
        fixture.model.connectionGeneration += 1
        #expect(session.leadMachineID == "alpha")
        #expect(session.leadStore == nil)
        #expect(session.leadUnavailableReason != nil)
        #expect(session.selection == .lead)
    }

    @Test("Uploads, sends, and unconfirmed delivery keep a single owner on Home")
    func blocksActiveOperations() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Direction")
        await fixture.controller.prepare()
        let featureID = try #require(fixture.controller.owner?.featureID)
        var item = attachment(featureID: featureID)
        item.status = .uploading
        item.uploaded = nil
        fixture.controller.store.composerDrafts.setAttachments([item], for: featureID)
        #expect(!fixture.controller.requestTransfer())
        #expect(fixture.controller.transferBlockReason?.contains("upload") == true)
        fixture.controller.store.composerDrafts.setAttachments([], for: featureID)
        let gate = ChatTestGate()
        fixture.client.beforeSend = { await gate.wait(); throw URLError(.networkConnectionLost) }
        let task = Task { await fixture.composer.productionView.dispatchSubmission() }
        try await waitFor(gate)
        #expect(!fixture.controller.requestTransfer())
        #expect(fixture.controller.transferBlockReason?.contains("send") == true)
        await gate.open()
        #expect(!(await task.value))
        #expect(!fixture.controller.requestTransfer())
        #expect(fixture.controller.transferBlockReason?.contains("unconfirmed") == true)
        #expect(fixture.controller.pendingTransfer == nil)
    }

    @Test("Home context uses the production frozen payload and original retry identity exactly once")
    func contextAndRetry() async throws {
        let fixture = Fixture()
        let context = HomeChatContext(title: "Observed on Home", summary: "Synthetic review is ready.")
        fixture.controller.open(context: context, draft: "Explain the review")
        await fixture.controller.prepare()
        #expect(fixture.client.sent.isEmpty)
        fixture.client.beforeSend = { throw APIError.server(status: 401, message: "Synthetic rejected send") }
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        let first = try #require(fixture.client.sent.first?.text)
        #expect(first.components(separatedBy: context.summary).count == 2)
        #expect(fixture.controller.contexts == [context])
        #expect(fixture.controller.draft == "Explain the review")
        let featureID = try #require(fixture.controller.owner?.featureID)
        let failure = try #require(fixture.controller.store.sendFailure(for: featureID))
        let handle = FirstMateOutgoingMessage.Handle(outgoingID: failure.id, requestID: failure.requestID,
            featureID: featureID, context: fixture.controller.store.operationContext)
        fixture.client.beforeSend = nil
        fixture.controller.store.composerDrafts.prepareRetry(handle, store: fixture.controller.store)
        let state = await fixture.controller.store.retryOutgoingMessage(handle)
        #expect(state?.isAcceptedAwaitingSnapshot == true)
        fixture.controller.store.composerDrafts.settle(handle, accepted: true, store: fixture.controller.store)
        #expect(fixture.client.sent.map(\.text) == [first, first])
        #expect(Set(fixture.client.sentRequestIDs).count == 1)
        #expect(fixture.controller.contexts.isEmpty)
    }

    @Test("Dismissing a tray retains its send and newer draft without enabling a stale source")
    func dismissalRetainsSend() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Original")
        await fixture.controller.prepare()
        let gate = ChatTestGate()
        fixture.client.beforeSend = { await gate.wait() }
        let composer = fixture.composer
        let task = Task { await composer.productionView.dispatchSubmission() }
        try await waitFor(gate)
        fixture.controller.setDraft("Newer")
        fixture.controller.dismiss()
        await gate.open()
        #expect(await task.value)
        #expect(fixture.controller.draft == "Newer")
        #expect(!fixture.controller.isPresented)
        #expect(fixture.client.sent.count == 1)
        fixture.controller.open()
        await fixture.controller.prepare()
        let beforeChange = fixture.composer.productionView
        fixture.model.connectionGeneration += 1
        #expect(!beforeChange.destination.isCurrent())
        #expect(!beforeChange.destination.acceptsCompletion())
        #expect(!(await beforeChange.dispatchSubmission()))
        #expect(fixture.client.sent.count == 1)
    }

    @Test("Disconnecting the owner rejects a captured composer immediately and keeps the draft")
    func disconnectDisablesControl() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Keep this draft")
        await fixture.controller.prepare()
        #expect(fixture.controller.canControl)
        let destination = fixture.composer.productionView
        fixture.model.machineStates["alpha"] = .disconnected
        #expect(fixture.controller.isOwnerCurrent)
        #expect(!fixture.controller.canControl)
        #expect(!destination.destination.isReadyToSubmit())
        #expect(!(await destination.dispatchSubmission()))
        #expect(fixture.client.sent.isEmpty)
        #expect(fixture.controller.draft == "Keep this draft")
        #expect(!fixture.controller.requestTransfer())
        await fixture.controller.prepare()
        #expect(!fixture.controller.store.controlAvailable)
        fixture.model.machineStates["alpha"] = .live
        await fixture.controller.prepare()
        #expect(fixture.controller.canControl)
        #expect(fixture.controller.draft == "Keep this draft")
    }

    @Test("Cancelling the receiving window restores Home's pending draft and permits another transfer")
    func cancelledWindowRestoresSource() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Try the transfer again")
        await fixture.controller.prepare()
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        let task = Task { await session.consumeHomeTransfer(from: fixture.controller) }
        try await waitFor(gate)
        task.cancel()
        await gate.open()
        #expect(!(await task.value))
        #expect(fixture.controller.pendingTransfer == nil)
        #expect(fixture.controller.canControl)
        #expect(fixture.controller.draft == "Try the transfer again")
        #expect(fixture.controller.isPresented)
        fixture.client.beforeEnsure = nil
        #expect(fixture.controller.requestTransfer())
        #expect(await session.consumeHomeTransfer(from: fixture.controller))
        #expect(session.leadStore?.draft == "Try the transfer again")
    }

    @Test("A captured skim reply rejects a stale Home owner before dispatch")
    func staleSkimReplyCannotSend() async throws {
        let fixture = Fixture()
        let featureID = "alpha-lead"
        var snapshot = try #require(fixture.client.snapshots[featureID])
        snapshot.messages = [.init(id: "synthetic-response", featureID: featureID,
            role: "assistant", text: "Choose a direction.", status: "delivered", createdAt: "2030-01-01T12:00:00Z")]
        fixture.client.snapshots = [featureID: snapshot]
        fixture.controller.open()
        await fixture.controller.prepare()
        let candidate = FirstMateSkimReplies.context(snapshot: snapshot,
            store: fixture.controller.store, canControl: fixture.controller.canControl,
            validateOwner: { fixture.controller.isOwnerControllable })
        let context = try #require(candidate)
        #expect(context.disabledReason == nil)
        fixture.model.connectionGeneration += 1
        #expect(!(await context.send("Proceed")))
        #expect(fixture.client.sent.isEmpty)
    }

    @Test("A newer window selection is not replaced by a delayed Home transfer")
    func newerWindowSelectionWins() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Keep this on Home")
        await fixture.controller.prepare()
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        let task = Task { await session.consumeHomeTransfer(from: fixture.controller) }
        try await waitFor(gate)
        let newer = FirstMateFleetFeatureID(machineID: "beta", featureID: "beta-feature")
        session.select(.feature(newer))
        await gate.open()
        #expect(!(await task.value))
        #expect(session.selection == .feature(newer))
        #expect(fixture.controller.draft == "Keep this on Home")
        #expect(fixture.controller.pendingTransfer == nil)
    }

    @Test("A retained Home draft does not block explicit features on a replacement connection")
    func retiredHomeLeadPreservesDraft() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Draft on the original connection")
        await fixture.controller.prepare()
        let session = fixture.window()
        #expect(fixture.controller.requestTransfer())
        #expect(await session.consumeHomeTransfer(from: fixture.controller))
        let original = try #require(session.leadStore)
        fixture.model.connectionGeneration += 1
        let target = FirstMateFleetFeatureID(machineID: "alpha", featureID: "another-feature")
        session.select(.feature(target))
        let replacement = try #require(session.selectedStore)
        #expect(replacement !== original)
        #expect(replacement.selectedFeatureID == target.featureID)
        #expect(original.draft == "Draft on the original connection")
        session.select(.lead)
        #expect(session.leadStore == nil)
        #expect(session.leadMachineID == "alpha")
        #expect(session.unavailableHomeDraft == "Draft on the original connection")
    }

    @Test("A queued native retry revalidates its owner before detaching or sending")
    func queuedRetryCannotSendAfterReconnect() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Retained failed message")
        await fixture.controller.prepare()
        fixture.client.beforeSend = { throw APIError.server(status: 401, message: "Synthetic rejected send") }
        #expect(!(await fixture.composer.productionView.dispatchSubmission()))
        let featureID = try #require(fixture.controller.owner?.featureID)
        let failure = try #require(fixture.controller.store.sendFailure(for: featureID))
        let retryView = FirstMateSendErrorView(store: fixture.controller.store, featureID: featureID,
            validateOwner: { fixture.controller.isOwnerControllable })
        let retry = try #require(retryView.retry(failure))
        fixture.model.connectionGeneration += 1
        await retry.value
        #expect(fixture.client.sent.count == 1)
        #expect(fixture.controller.draft == "Retained failed message")
    }

    @Test("Concurrent window hydration of the exact lead does not reject a Home transfer")
    func concurrentLeadHydration() async throws {
        let fixture = Fixture()
        fixture.controller.open(draft: "Arrive once")
        await fixture.controller.prepare()
        let session = fixture.window()
        let destination = try #require(session.store(for: "alpha"))
        let gate = ChatTestGate()
        fixture.client.beforeEnsure = { await gate.wait() }
        #expect(fixture.controller.requestTransfer())
        let transfer = Task { await session.consumeHomeTransfer(from: fixture.controller) }
        try await waitFor(gate)
        fixture.client.beforeEnsure = nil
        #expect(await destination.openLead())
        await gate.open()
        #expect(await transfer.value)
        #expect(destination.draft == "Arrive once")
        #expect(session.homeLeadOwner?.featureID == "alpha-lead")
        #expect(fixture.controller.pendingTransfer == nil)
    }

    @Test("Read markers require the current owner, visible newest content, and the key window")
    func staleOrHiddenTranscriptCannotMarkRead() async throws {
        let model = ChatFixtures.model(demo: true)
        let shell = ChatFixtures.shell()
        let session = FirstMateChatWindowSession(model: model, shell: shell)
        let id = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")
        session.select(.feature(id))
        let store = try #require(session.selectedStore)
        let snapshot = try #require(store.snapshots[id.featureID])
        var ownerIsCurrent = false
        let transcript = FirstMateChatTranscript(session: session, store: store, snapshot: snapshot,
            conversationID: id, isTyping: false, validateOwner: { ownerIsCurrent })
        transcript.markReadIfVisible(isKeyWindow: true, isAtBottom: true)
        ownerIsCurrent = true
        transcript.markReadIfVisible(isKeyWindow: false, isAtBottom: true)
        transcript.markReadIfVisible(isKeyWindow: true, isAtBottom: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(shell.firstMateFleet.readState.overrides[id] == nil)
        transcript.markReadIfVisible(isKeyWindow: true, isAtBottom: true)
        ownerIsCurrent = false
        for _ in 0..<20 { await Task.yield() }
        #expect(shell.firstMateFleet.readState.overrides[id] == nil)
        ownerIsCurrent = true
        transcript.markReadIfVisible(isKeyWindow: true, isAtBottom: true)
        try await ChatFixtures.waitUntil("visible current transcript read") {
            shell.firstMateFleet.readState.overrides[id] != nil
        }
    }

    private func waitFor(_ gate: ChatTestGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.arrived) {
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "Home transfer gate") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func attachment(featureID: String) -> TerminalAttachment {
        .init(id: UUID(), filename: "synthetic.txt", sourceURL: URL(fileURLWithPath: "/tmp/synthetic.txt"), byteCount: 8,
              sourceOwnership: .userSelected, status: .uploaded,
              uploaded: .init(id: UUID().uuidString, filename: "synthetic.txt", originalFilename: "synthetic.txt",
                              contentType: "text/plain", size: 8, path: "/tmp/first-mate/synthetic.txt",
                              workspaceID: "first-mate:" + featureID, createdAt: "2026-10-03T12:00:00Z"), error: nil)
    }

    @MainActor
    private final class Fixture {
        let model: HerdrAppModel
        let shell: HerdrShellState
        let client: SyntheticChatFleetClient
        let controller: HomeChatController
        let configuration: ServerConfiguration
        init() {
            model = ChatFixtures.model(demo: false)
            model.machines = [.init(id: "alpha", name: "Alpha", urlString: "https://alpha.example"),
                              .init(id: "beta", name: "Beta", urlString: "https://beta.example")]
            model.machineStates = ["alpha": .live, "beta": .live]
            shell = ChatFixtures.shell()
            client = Self.client(featureID: "alpha-lead")
            configuration = ServerConfiguration(urlString: "https://alpha.example", token: "synthetic")!
            let config = configuration
            let transport = self.client
            controller = HomeChatController(model: model, shell: shell, configuration: { _ in config },
                makeClient: { _ in transport }, chooseMachine: { "alpha" })
        }

        var composer: FirstMatePromptComposer {
            let owner = controller.owner
            return FirstMatePromptComposer(store: controller.store, model: model, snapshot: controller.snapshot!,
                canControl: controller.canControl, modelFavorites: ModelFavoritesStore(),
                validateOwner: { [controller] in controller.owner == owner && controller.isOwnerControllable })
        }

        func window(client replacement: SyntheticChatFleetClient? = nil) -> FirstMateChatWindowSession {
            let config = configuration
            let transport = replacement ?? self.client
            return FirstMateChatWindowSession(model: model, shell: shell, configuration: { _ in config }, makeClient: { _ in transport })
        }

        static func client(featureID: String) -> SyntheticChatFleetClient {
            var feature = ChatFixtures.feature(featureID, title: "Synthetic lead", status: "ready")
            feature.kind = "lead"
            let client = SyntheticChatFleetClient(capabilities: .success(["first-mate-v1", "first-mate-lead-v1", "first-mate-attachments-v1"]), features: [feature])
            client.lead = .init(feature: feature, unread: false, workingOnReply: false, latestMessage: nil)
            client.snapshots = [featureID: .init(feature: feature)]
            return client
        }
    }
}

@MainActor
private final class LeadChoice {
    var machineID = "alpha"
}
