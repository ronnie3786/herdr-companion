import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Phone composer material and exact owner", .serialized)
@MainActor
struct FirstMateMobileComposerTests {
    @Test("Attachments, mentions and dictation freeze together; failure cannot replace even an identical newer edit")
    func frozenMaterial() async throws {
        let fixture = try await MobileComposerFixture()
        let context = fixture.store.operationContext
        let url = try fixture.file("notes.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        fixture.material.enqueue([try AttachmentPolicy.candidate(for: url, ownership: .userSelected)],
            store: fixture.store, context: context, generation: fixture.material.generation, canUpload: { fixture.current })
        try await fixture.wait { fixture.material.attachments.first?.status == .uploaded }
        #expect(FileManager.default.fileExists(atPath: url.path), "A user's source is never deleted")
        fixture.material.edit("@Sibling", store: fixture.store, context: context)
        #expect(fixture.material.receiveVoice("Explain this file", initialRevision: fixture.material.revision,
            initialText: "@Sibling", store: fixture.store, context: context))
        let draft = fixture.store.draft
        fixture.alphaBase.beforeSend = { throw URLError(.timedOut) }
        let handle = try #require(FirstMateMobileSubmission.begin(store: fixture.store, target: fixture.target,
            fleet: fixture.fleet, canControl: true, material: fixture.material))
        let payload = try #require(fixture.store.outgoingMessage(handle)?.text)
        #expect(payload.contains("herdr://first-mate?feature_id=sibling"))
        #expect(payload.contains("Attachment: `synthetic/notes.txt`"))
        #expect(payload.components(separatedBy: FirstMateMessageDisplay.dictationSuffix).count == 2)
        #expect(fixture.material.attachments.isEmpty && fixture.store.draft.isEmpty)
        fixture.material.edit(draft, store: fixture.store, context: context)
        let failure = await fixture.store.completeOutgoingMessage(handle)
        fixture.material.settle(handle, state: failure, store: fixture.store)
        #expect(fixture.store.draft == draft && fixture.material.attachments.isEmpty)
        let outgoing = try #require(fixture.store.sendFailure(for: fixture.target.featureID))
        let retry = try #require(FirstMateMobileSubmission.retryHandle(outgoing, store: fixture.store,
            target: fixture.target, fleet: fixture.fleet, canControl: true))
        fixture.material.prepareRetry(retry, store: fixture.store)
        fixture.alphaBase.beforeSend = nil
        let accepted = await fixture.store.retryOutgoingMessage(retry)
        fixture.material.settle(retry, state: accepted, store: fixture.store)
        #expect(fixture.store.draft == draft)
        #expect(fixture.alphaBase.sentRequestIDs == [handle.requestID, handle.requestID])
        #expect(fixture.alphaBase.sent.allSatisfy { $0.text == payload && $0.featureID == fixture.target.featureID })
        #expect(fixture.betaBase.sent.isEmpty)
    }

    @Test("Untouched failed material restores once; explicit retry detaches only that restoration")
    func restoredRetry() async throws {
        let fixture = try await MobileComposerFixture()
        fixture.material.edit("Original", store: fixture.store, context: fixture.store.operationContext)
        fixture.alphaBase.beforeSend = { throw URLError(.timedOut) }
        let handle = try #require(FirstMateMobileSubmission.begin(store: fixture.store, target: fixture.target,
            fleet: fixture.fleet, canControl: true, material: fixture.material))
        fixture.material.settle(handle, state: await fixture.store.completeOutgoingMessage(handle), store: fixture.store)
        #expect(fixture.store.draft == "Original")
        fixture.material.prepareRetry(handle, store: fixture.store)
        #expect(fixture.store.draft.isEmpty)
        fixture.alphaBase.beforeSend = nil
        fixture.material.settle(handle, state: await fixture.store.retryOutgoingMessage(handle), store: fixture.store)
        #expect(fixture.store.draft.isEmpty)
    }

    @Test("Held upload remains with its original conversation; source replacement discards owned material", arguments: [false, true])
    func heldUpload(replace: Bool) async throws {
        let fixture = try await MobileComposerFixture()
        let gate = ChatTestGate()
        await fixture.alpha.setUploadGate(gate)
        let url = try fixture.file("owned.txt")
        fixture.material.enqueue([try AttachmentPolicy.candidate(for: url, ownership: .appTemporary)],
            store: fixture.store, context: fixture.store.operationContext, generation: fixture.material.generation,
            canUpload: { fixture.current })
        defer { Task { await gate.open() }; try? FileManager.default.removeItem(at: url) }
        try await fixture.wait { await gate.arrived }
        if replace { fixture.fleet.activate(sources: fixture.sources(token: "replacement"), connectionGeneration: 1) }
        else { #expect(fixture.fleet.open(.init(machineID: "beta", featureID: "feature"))) }
        await gate.open()
        try await fixture.wait { !fixture.material.attachments.contains { $0.status == .uploading } }
        #expect(await fixture.alpha.uploadCalls == ["feature"])
        #expect(await fixture.beta.uploadCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        if replace { #expect(fixture.material.attachments.isEmpty) }
        else { #expect(fixture.material.attachments.first?.uploadedPath == "synthetic/owned.txt") }
    }

    @Test("Failed upload retries on its owner, and stale preparations clean only their owned files")
    func uploadRetryAndStaleImport() async throws {
        let fixture = try await MobileComposerFixture()
        await fixture.alpha.setUploadFails(true)
        let owned = try fixture.file("retry.txt")
        fixture.material.enqueue([try AttachmentPolicy.candidate(for: owned, ownership: .appTemporary)],
            store: fixture.store, context: fixture.store.operationContext, generation: fixture.material.generation,
            canUpload: { fixture.current })
        try await fixture.wait { fixture.material.attachments.first?.status == .failed }
        #expect(fixture.material.blocksSending)
        #expect(FileManager.default.fileExists(atPath: owned.path), "The failed upload retains its source for explicit retry")
        let item = try #require(fixture.material.attachments.first)
        await fixture.alpha.setUploadFails(false)
        fixture.material.retry(item, store: fixture.store, context: fixture.store.operationContext, canUpload: { fixture.current })
        try await fixture.wait { fixture.material.attachments.first?.status == .uploaded }
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        let stale = fixture.material.generation
        fixture.material.edit("Send the file", store: fixture.store, context: fixture.store.operationContext)
        _ = try #require(FirstMateMobileSubmission.begin(store: fixture.store, target: fixture.target,
            fleet: fixture.fleet, canControl: true, material: fixture.material))
        let late = try fixture.file("late-photo.jpg"), user = try fixture.file("user.pdf")
        defer { try? FileManager.default.removeItem(at: user) }
        fixture.material.enqueue([try AttachmentPolicy.candidate(for: late, ownership: .appTemporary),
            try AttachmentPolicy.candidate(for: user, ownership: .userSelected)], store: fixture.store,
            context: fixture.store.operationContext, generation: stale, canUpload: { fixture.current })
        #expect(!FileManager.default.fileExists(atPath: late.path))
        #expect(FileManager.default.fileExists(atPath: user.path))
        #expect(fixture.material.attachments.isEmpty)
        #expect(await fixture.alpha.uploadCalls.count == 2)
    }

    @Test("Material limits reject a whole import and leave another machine's draft untouched")
    func limitsAndOwners() async throws {
        let fixture = try await MobileComposerFixture()
        let file = try fixture.file("too-many.txt")
        let candidate = try AttachmentPolicy.candidate(for: file, ownership: .appTemporary)
        fixture.material.enqueue(Array(repeating: candidate, count: 11), store: fixture.store,
            context: fixture.store.operationContext, generation: fixture.material.generation, canUpload: { fixture.current })
        #expect(fixture.material.error?.contains("10") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await fixture.alpha.uploadCalls.isEmpty)
        fixture.material.edit("Alpha text", store: fixture.store, context: fixture.store.operationContext)
        let betaTarget = FirstMateFeatureTarget(machineID: "beta", featureID: "feature")
        #expect(fixture.fleet.open(betaTarget))
        let betaStore = try #require(fixture.fleet.store(for: betaTarget))
        let betaDraft = fixture.fleet.chat.composerDrafts.draft(for: betaTarget, store: betaStore)
        betaDraft.edit("Beta text", store: betaStore, context: betaStore.operationContext)
        #expect(fixture.fleet.open(fixture.target))
        #expect(fixture.store.draft == "Alpha text")
        #expect(fixture.material !== betaDraft)
    }

    @Test("Voice uses the captured client, then Apple; cancellation never enters fallback", arguments: [false, true])
    func voiceFallback(cancelled: Bool) async throws {
        let fixture = try await MobileComposerFixture(), gate = ChatTestGate(), counter = MobileComposerCounter()
        await fixture.alpha.setVoiceGate(gate)
        let context = fixture.store.operationContext
        let file = try fixture.file("voice.wav")
        defer { try? FileManager.default.removeItem(at: file); Task { await gate.open() } }
        let task = Task {
            try await FirstMateMobileVoiceController.transcribe(file, store: fixture.store, context: context,
                isCurrent: { fixture.current }, apple: { _ in
                    await counter.increment()
                    return .init(text: "Apple synthetic result", provider: .apple, language: nil, usedFallback: false)
                })
        }
        try await fixture.wait { await gate.arrived }
        if cancelled { task.cancel() }
        await gate.open()
        if cancelled {
            do { _ = try await task.value; Issue.record("Cancelled voice unexpectedly completed") }
            catch is CancellationError { }
            #expect(await counter.count == 0)
        } else {
            let result = try await task.value
            #expect(result.usedFallback && result.text == "Apple synthetic result")
            #expect(await counter.count == 1)
        }
        #expect(await fixture.alpha.voiceCalls == 1)
        #expect(await fixture.beta.voiceCalls == 0)
    }

    @Test("Recognized text stays with its original draft and never overwrites newer edits")
    func recognizedText() async throws {
        let fixture = try await MobileComposerFixture(), context = fixture.store.operationContext
        let revision = fixture.material.revision
        fixture.material.edit("Newer edit", store: fixture.store, context: context)
        #expect(!fixture.material.receiveVoice("Recognized", initialRevision: revision, initialText: "", store: fixture.store, context: context))
        #expect(fixture.store.draft == "Newer edit" && fixture.material.recoveredVoice == "Recognized")
        let latest = fixture.material.revision
        #expect(fixture.fleet.open(.init(machineID: "beta", featureID: "feature")))
        #expect(fixture.material.receiveVoice("Saved on alpha", initialRevision: latest, initialText: "Newer edit", store: fixture.store, context: context))
        #expect(fixture.store.composerDraft(for: context) == "Newer edit\nSaved on alpha")
        #expect(fixture.fleet.store(forMachineID: "beta")?.draft == "")
    }

    @Test("Model enablement requires real control and rejects queued, pending, closed and stale contexts")
    func modelEnablement() async throws {
        let fixture = try await MobileComposerFixture(), context = fixture.store.operationContext
        #expect(FirstMateMobileModelPolicy.unavailableReason(store: fixture.store, context: context, canControl: true) == nil)
        fixture.store.updateControlLease(fixture.lease, available: false)
        #expect(FirstMateMobileModelPolicy.unavailableReason(store: fixture.store, context: context, canControl: true) != nil)
        fixture.store.updateControlLease(fixture.lease, available: true)
        for state in ["closed", "owner", "queued"] {
            var snapshot = try #require(fixture.store.snapshot)
            let original = snapshot
            switch state {
            case "closed": snapshot.feature.status = "completed"
            case "owner": snapshot.feature.coordinatorOwner = "synthetic-owner"
            case "queued": snapshot.messages = [.init(id: "queued", featureID: "feature", role: "user", text: "Wait", status: "queued", createdAt: FirstMateDemo.timestamp)]
            default: snapshot.feature.modelSettingsRevision = nil
            }
            fixture.store.receive(snapshot)
            #expect(FirstMateMobileModelPolicy.unavailableReason(store: fixture.store, context: context, canControl: true) != nil)
            fixture.store.receive(original)
        }
        fixture.material.edit("Pending", store: fixture.store, context: context)
        _ = try #require(FirstMateMobileSubmission.begin(store: fixture.store, target: fixture.target, fleet: fixture.fleet, canControl: true))
        #expect(fixture.store.isSubmitting(featureID: "feature") && !fixture.store.isSending)
        #expect(FirstMateMobileModelPolicy.unavailableReason(store: fixture.store, context: context, canControl: true) != nil)
        #expect(fixture.fleet.open(.init(machineID: "beta", featureID: "feature")))
        #expect(FirstMateMobileModelPolicy.unavailableReason(store: fixture.store, context: fixture.fleet.store(forMachineID: "beta")!.operationContext, canControl: true) != nil)
    }

    @Test("Rating requests accept older closed replies and reject local IDs and changed sources")
    func feedbackIdentity() async throws {
        let fixture = try await MobileComposerFixture()
        var snapshot = try #require(fixture.store.snapshot)
        snapshot.feature.status = "completed"
        let reply = FirstMateMessage(id: "older-server-reply", featureID: "feature", role: "assistant", text: "Retained response", status: "done", createdAt: FirstMateDemo.timestamp)
        snapshot.messages = [reply]; fixture.store.receive(snapshot)
        let request = try #require(FirstMateMobileFeedbackRequest.capture(reply, target: fixture.target, store: fixture.store, fleet: fixture.fleet))
        #expect(request.isCurrent(fleet: fixture.fleet))
        var local = reply; local.id = FirstMateOutgoingMessage.makeLocalID(); snapshot.messages.append(local); fixture.store.receive(snapshot)
        #expect(FirstMateMobileFeedbackRequest.capture(local, target: fixture.target, store: fixture.store, fleet: fixture.fleet) == nil)
        fixture.fleet.activate(sources: fixture.sources(token: "new-source"), connectionGeneration: 1)
        #expect(!request.isCurrent(fleet: fixture.fleet))
    }

}

@MainActor
final class MobileComposerFixture {
    let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "Composer.\(UUID())")!)
    let target = FirstMateFeatureTarget(machineID: "alpha", featureID: "feature")
    let alphaBase: SyntheticChatFleetClient
    let betaBase: SyntheticChatFleetClient
    let alpha: MobileComposerClient
    let beta: MobileComposerClient
    let store: FirstMateStore
    let material: FirstMateMobileComposerDraft
    let lease: FirstMateStore.ControlLease
    var current: Bool { fleet.store(for: target) === store && fleet.selectedTarget == target && store.controlAvailable }
    init() async throws {
        var feature = ChatFixtures.feature("feature", status: "blocked"); feature.modelSettingsRevision = 1
        let sibling = ChatFixtures.feature("sibling", title: "Sibling", status: "blocked")
        let caps = ["first-mate-v1", "first-mate-fleet-v1", "first-mate-attachments-v1", "first-mate-safe-model-settings-v1", "first-mate-feedback-v1"]
        alphaBase = SyntheticChatFleetClient(capabilities: .success(caps), features: [feature, sibling])
        betaBase = SyntheticChatFleetClient(capabilities: .success(caps), features: [feature])
        alphaBase.snapshots = [feature.id: FirstMateSnapshot(feature: feature), sibling.id: FirstMateSnapshot(feature: sibling)]
        betaBase.snapshots = [feature.id: FirstMateSnapshot(feature: feature)]
        alpha = MobileComposerClient(base: alphaBase); beta = MobileComposerClient(base: betaBase)
        let a = ChatFixtures.machine("alpha"), b = ChatFixtures.machine("beta")
        fleet.activate(sources: [.init(machine: a, configuration: .init(urlString: a.urlString, token: "synthetic"), client: alpha),
            .init(machine: b, configuration: .init(urlString: b.urlString, token: "synthetic"), client: beta)], connectionGeneration: 1)
        await fleet.refreshAll()
        #expect(fleet.open(target))
        store = try #require(fleet.store(for: target))
        await store.refresh()
        lease = store.acquireControlLease(available: true)
        material = fleet.chat.composerDrafts.draft(for: target, store: store)
    }
    func sources(token: String) -> [FirstMateMobileFleetSource] {
        let a = ChatFixtures.machine("alpha"), b = ChatFixtures.machine("beta")
        return [.init(machine: a, configuration: .init(urlString: a.urlString, token: token), client: alpha),
                .init(machine: b, configuration: .init(urlString: b.urlString, token: "synthetic"), client: beta)]
    }
    func file(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "composer-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name); try Data("Synthetic file contents".utf8).write(to: file)
        return file
    }
    func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Timed out waiting for composer operation")
    }
}

actor MobileComposerCounter { private(set) var count = 0; func increment() { count += 1 } }

actor MobileComposerClient: FirstMateClient {
    let base: SyntheticChatFleetClient
    private var uploadGate: ChatTestGate?
    private var voiceGate: ChatTestGate?
    private var uploadFails = false
    private(set) var uploadCalls: [String] = []
    private(set) var voiceCalls = 0
    init(base: SyntheticChatFleetClient) { self.base = base }
    func setUploadGate(_ gate: ChatTestGate) { uploadGate = gate }
    func setVoiceGate(_ gate: ChatTestGate) { voiceGate = gate }
    func setUploadFails(_ value: Bool) { uploadFails = value }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { try await base.fetchFirstMateCapabilities() }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await base.fetchFirstMateFeatures() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { try await base.fetchFirstMateFeature(id) }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse { try await base.fetchFirstMateFleet() }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { try await base.sendFirstMateMessage(featureID: featureID, text: text, requestID: requestID) }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
    func uploadFirstMateAttachment(featureID: String, fileURL: URL, contentType: String) async throws -> AttachmentUploadResponse {
        uploadCalls.append(featureID); await uploadGate?.wait()
        if uploadFails { throw URLError(.timedOut) }
        return .init(ok: true, attachment: .init(id: "synthetic", filename: fileURL.lastPathComponent,
            originalFilename: fileURL.lastPathComponent, contentType: contentType, size: 23,
            path: "synthetic/" + fileURL.lastPathComponent, workspaceID: nil, createdAt: FirstMateDemo.timestamp))
    }
    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        voiceCalls += 1; await voiceGate?.wait(); throw URLError(.cannotConnectToHost)
    }
}
