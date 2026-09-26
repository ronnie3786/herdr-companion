import Foundation
import Testing
@testable import herdr_harness_ios

/// Proves that every mobile First Mate mutation or read resolves through the
/// exact owning machine's client, including when two hosts share a feature ID.
@Suite("First Mate mobile routing", .serialized)
@MainActor
struct FirstMateMobileRoutingTests {
    @Test("Create, message, archive, and resource reads reach only the owning host")
    func exactOwnerRoutingForEveryOperation() async throws {
        let recorder = RoutingRecorder()
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let lifecycle = fleet.activate(sources: [
            source(alpha, client("alpha", snapshots: [snapshot(id: "shared", title: "Alpha shared")], recorder: recorder)),
            source(beta, client("beta", snapshots: [snapshot(id: "shared", title: "Beta shared")], recorder: recorder)),
        ], connectionGeneration: 1)
        await fleet.refresh(lifecycle: lifecycle)

        let alphaTarget = FirstMateFeatureTarget(machineID: "alpha", featureID: "shared")
        let betaTarget = FirstMateFeatureTarget(machineID: "beta", featureID: "shared")
        let alphaStore = try #require(fleet.store(for: alphaTarget))
        let betaStore = try #require(fleet.store(for: betaTarget))
        #expect(alphaStore !== betaStore)
        #expect(fleet.open(alphaTarget))

        // Message
        alphaStore.select("shared")
        alphaStore.draft = "Keep the alpha plan."
        let messageContext = alphaStore.operationContext
        await alphaStore.send(expectedContext: messageContext)
        #expect(alphaStore.draft.isEmpty)

        // Create through the fleet's composite destination, which mirrors the
        // new row back into the combined list for the owning host only.
        let created = await fleet.create(
            on: "alpha",
            title: "Alpha follow-up",
            goal: "Only on alpha",
            cwd: "/tmp/synthetic",
            requestID: "alpha-create-1",
            expectedContext: alphaStore.operationContext
        )
        #expect(created == FirstMateFeatureTarget(machineID: "alpha", featureID: "alpha-created-alpha-create-1"))
        #expect(fleet.visibleRows.contains { $0.featureID == "alpha-created-alpha-create-1" && $0.machineID == "alpha" })
        #expect(!fleet.visibleRows.contains { $0.featureID == "alpha-created-alpha-create-1" && $0.machineID == "beta" })

        // Archive and unarchive through the fleet helper.
        #expect(await fleet.setArchived(
            alphaTarget,
            archived: true,
            expectedContext: alphaStore.operationContext
        ))
        #expect(await fleet.setArchived(
            alphaTarget,
            archived: false,
            expectedContext: alphaStore.operationContext
        ))

        // Document read
        alphaStore.select("shared")
        let document = try #require(alphaStore.snapshot?.documents.first)
        await alphaStore.open(.document(document))
        #expect(alphaStore.resourceText.contains("Synthetic document preview"))

        // Saved-session read
        let session = try #require(alphaStore.snapshot?.sessions.first)
        await alphaStore.open(.history(session))
        #expect(alphaStore.sessionMessages?.isEmpty == false)

        let calls = await recorder.calls
        let alphaCalls = calls.filter { $0.hasPrefix("alpha:") }
        let betaCalls = calls.filter { $0.hasPrefix("beta:") }
        #expect(alphaCalls.contains { $0 == "alpha:create:Alpha follow-up:alpha-create-1" })
        #expect(alphaCalls.contains { $0.hasPrefix("alpha:message:shared:Keep the alpha plan.") })
        #expect(alphaCalls.contains { $0.hasPrefix("alpha:archive:shared:true") })
        #expect(alphaCalls.contains { $0.hasPrefix("alpha:archive:shared:false") })
        #expect(alphaCalls.contains { $0 == "alpha:document:doc-shared" })
        #expect(alphaCalls.contains { $0 == "alpha:session:session-shared" })
        // Beta only ever answered reads for its own duplicate feature ID.
        #expect(!betaCalls.contains { call in
            call.contains(":create:") || call.contains(":message:")
                || call.contains(":archive:") || call.contains(":document:") || call.contains(":session:")
        })
        #expect(betaCalls.contains { $0.hasPrefix("beta:feature:shared") })
        #expect(fleet.resolvedScope == .all)
    }

    @Test("A captured context from another host is rejected without any request")
    func crossHostContextIsRejected() async throws {
        let recorder = RoutingRecorder()
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let lifecycle = fleet.activate(sources: [
            source(alpha, client("alpha", snapshots: [snapshot(id: "shared", title: "Alpha shared")], recorder: recorder)),
            source(beta, client("beta", snapshots: [snapshot(id: "shared", title: "Beta shared")], recorder: recorder)),
        ], connectionGeneration: 2)
        await fleet.refresh(lifecycle: lifecycle)

        let alphaStore = try #require(fleet.store(forMachineID: "alpha"))
        let betaStore = try #require(fleet.store(forMachineID: "beta"))
        alphaStore.select("shared")
        alphaStore.draft = "Alpha-only direction"
        let alphaContext = alphaStore.operationContext

        // The same feature ID on beta must not accept alpha's lifecycle context.
        await betaStore.send(expectedContext: alphaContext)
        #expect(!(await betaStore.create(
            title: "Wrong host",
            goal: "Must never be created",
            cwd: "/tmp/synthetic",
            requestID: "cross-host-create",
            expectedContext: alphaContext
        )))
        #expect(!(await fleet.setArchived(
            FirstMateFeatureTarget(machineID: "beta", featureID: "shared"),
            archived: true,
            expectedContext: alphaContext
        )))

        let calls = await recorder.calls.filter { $0.hasPrefix("beta:") }
        #expect(!calls.contains { $0.contains(":message:") || $0.contains(":create:") || $0.contains(":archive:") })
    }

    @Test("A delayed create from a stale dialog cannot reach a replacement connection")
    func delayedCreateFencesTheStaleDialog() async throws {
        let recorder = RoutingRecorder()
        let gate = RoutingGate()
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let gated = client(
            "alpha-stale",
            snapshots: [snapshot(id: "shared", title: "Alpha shared")],
            recorder: recorder,
            create: { _, _, _, _ in try await gate.create() }
        )
        let lifecycle = fleet.activate(sources: [source(alpha, gated)], connectionGeneration: 3)
        await fleet.refresh(lifecycle: lifecycle)
        let staleStore = try #require(fleet.store(forMachineID: "alpha"))
        staleStore.select("shared")
        let staleContext = staleStore.operationContext

        let operation = Task {
            await staleStore.create(
                title: "Delayed create",
                goal: "Must never reach a replacement host",
                cwd: "/tmp/synthetic",
                requestID: "delayed-create",
                expectedContext: staleContext
            )
        }
        try await gate.waitForRequest()

        let replacement = client("alpha-replacement", snapshots: [snapshot(id: "replacement", title: "Replacement")], recorder: recorder)
        _ = fleet.activate(
            sources: [source(machine("alpha", "Alpha Mac"), replacement, token: "rotated-token")],
            connectionGeneration: 3
        )
        #expect(fleet.store(forMachineID: "alpha") !== staleStore)
        #expect(staleStore.features.isEmpty)

        await gate.succeed(snapshot(id: "delayed", title: "Delayed"))
        #expect(await operation.value == false)
        #expect(staleStore.features.isEmpty)

        let calls = await recorder.calls
        #expect(!calls.contains { $0.hasPrefix("alpha-replacement:create:") })
        #expect(!calls.contains { $0.contains("Delayed create") && $0.hasPrefix("alpha-replacement:") })
    }

    @Test("A removed owner rejects delayed confirmations and is never substituted")
    func removedOwnerFencesDelayedConfirmation() async throws {
        let recorder = RoutingRecorder()
        let fleet = FirstMateMobileFleetStore(defaults: isolatedDefaults())
        let alpha = machine("alpha", "Alpha Mac")
        let beta = machine("beta", "Beta Mac")
        let lifecycle = fleet.activate(sources: [
            source(alpha, client("alpha", snapshots: [snapshot(id: "shared", title: "Alpha shared")], recorder: recorder)),
            source(beta, client("beta", snapshots: [snapshot(id: "shared", title: "Beta shared")], recorder: recorder)),
        ], connectionGeneration: 4)
        await fleet.refresh(lifecycle: lifecycle)
        let alphaTarget = FirstMateFeatureTarget(machineID: "alpha", featureID: "shared")
        let removedStore = try #require(fleet.store(for: alphaTarget))
        removedStore.select("shared")
        let staleContext = removedStore.operationContext

        // Re-activate without alpha. The retired store keeps no client.
        _ = fleet.activate(
            sources: [source(beta, client("beta", snapshots: [snapshot(id: "shared", title: "Beta shared")], recorder: recorder))],
            connectionGeneration: 4
        )
        #expect(fleet.store(for: alphaTarget) == nil)
        #expect(fleet.selectedTarget == nil)
        #expect(!fleet.open(alphaTarget))
        #expect(!(await fleet.setArchived(alphaTarget, archived: true, expectedContext: staleContext)))
        #expect(!(await removedStore.create(
            title: "Removed owner",
            goal: "Must never be created elsewhere",
            cwd: "/tmp/synthetic",
            requestID: "removed-owner",
            expectedContext: staleContext
        )))
        let calls = await recorder.calls
        #expect(!calls.contains { $0.hasPrefix("beta:create:Removed owner") })
        #expect(!calls.contains { $0.hasPrefix("beta:archive:") })
    }

    // MARK: - Helpers

    private func isolatedDefaults() -> UserDefaults {
        let name = "FirstMateMobileRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func machine(_ id: String, _ name: String) -> HerdrMachine {
        HerdrMachine(id: id, name: name, urlString: "https://\(id).example.invalid")
    }

    private func configuration(_ machine: HerdrMachine, _ token: String) -> ServerConfiguration {
        ServerConfiguration(urlString: machine.urlString, token: token)!
    }

    private func source(
        _ machine: HerdrMachine,
        _ client: RecordingFleetClient,
        token: String? = nil
    ) -> FirstMateMobileFleetSource {
        FirstMateMobileFleetSource(
            machine: machine,
            configuration: configuration(machine, token ?? "\(machine.id)-token"),
            client: client
        )
    }

    private func client(
        _ identity: String,
        snapshots: [FirstMateSnapshot],
        recorder: RoutingRecorder,
        create: (@Sendable (String, String, String, String) async throws -> FirstMateSnapshot)? = nil
    ) -> RecordingFleetClient {
        RecordingFleetClient(
            identity: identity,
            snapshots: snapshots,
            recorder: recorder,
            create: create
        )
    }

    private func snapshot(id: String, title: String, status: String = "running") -> FirstMateSnapshot {
        var value = FirstMateDemo.newFeature(title: title, goal: "Synthetic goal for \(title)", cwd: "/tmp/synthetic", id: id)
        value.feature.status = status
        value.visits = [FirstMateVisit(
            id: "visit-\(id)",
            featureID: id,
            stageKey: "plan",
            title: "Planning",
            status: "completed",
            revision: 1,
            createdAt: FirstMateDemo.timestamp
        )]
        value.feature.currentVisitID = "visit-\(id)"
        value.documents = [FirstMateDocument(
            id: "doc-\(id)",
            featureID: id,
            visitID: "visit-\(id)",
            assignmentID: nil,
            nativeSessionID: nil,
            title: "\(title) plan.md",
            mediaType: "text/markdown",
            contentHash: "synthetic-hash",
            createdAt: FirstMateDemo.timestamp,
            content: "# Plan\n\nSynthetic document preview"
        )]
        value.sessions = [FirstMateSession(
            nativeSessionID: "session-\(id)",
            featureID: id,
            assignmentID: nil,
            title: "\(title) session",
            role: "first_mate",
            status: "active",
            generation: 1,
            createdAt: FirstMateDemo.timestamp,
            updatedAt: FirstMateDemo.timestamp,
            ownershipStatus: "active",
            kind: "coordinator"
        )]
        return value
    }
}

/// Records an ordered, machine-attributed request log for assertions.
private actor RoutingRecorder {
    private(set) var calls: [String] = []

    func record(_ call: String) { calls.append(call) }
}

/// A `FirstMateClient` that answers with synthetic snapshots for one identity
/// and records every request with that identity, so a test can prove which host
/// received each operation.
private actor RecordingFleetClient: FirstMateClient {
    private let identity: String
    private var snapshots: [String: FirstMateSnapshot]
    private var featureOrder: [FirstMateFeature]
    private let recorder: RoutingRecorder
    private let createHandler: (@Sendable (String, String, String, String) async throws -> FirstMateSnapshot)?

    init(
        identity: String,
        snapshots: [FirstMateSnapshot],
        recorder: RoutingRecorder,
        create: (@Sendable (String, String, String, String) async throws -> FirstMateSnapshot)? = nil
    ) {
        self.identity = identity
        self.snapshots = Dictionary(snapshots.map { ($0.feature.id, $0) }, uniquingKeysWith: { _, latest in latest })
        featureOrder = snapshots.map(\.feature)
        self.recorder = recorder
        createHandler = create
    }

    func fetchFirstMateModels() async throws -> FirstMateModelCatalog {
        .init(ok: true, models: [], defaultModel: "", thinkingLevels: [])
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        await recorder.record("\(identity):capabilities")
        return .init(ok: true, capabilities: ["first-mate-archive-v1"])
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        await recorder.record("\(identity):list")
        return .init(ok: true, features: featureOrder.filter { !$0.isArchived })
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        await recorder.record("\(identity):list:\(scope.rawValue)")
        let features: [FirstMateFeature] = switch scope {
        case .active: featureOrder.filter { !$0.isArchived }
        case .archived: featureOrder.filter(\.isArchived)
        case .all: featureOrder
        }
        return .init(ok: true, features: features)
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        await recorder.record("\(identity):feature:\(id)")
        guard let snapshot = snapshots[id] else { throw APIError.invalidResponse }
        return snapshot
    }

    func fetchFirstMateFeature(_ id: String, journalEventsOnly: Bool) async throws -> FirstMateSnapshot {
        try await fetchFirstMateFeature(id)
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        await recorder.record("\(identity):create:\(title):\(requestID)")
        let snapshot: FirstMateSnapshot
        if let createHandler {
            snapshot = try await createHandler(title, goal, cwd, requestID)
        } else {
            snapshot = FirstMateDemo.newFeature(title: title, goal: goal, cwd: cwd, id: "\(identity)-created-\(requestID)")
        }
        snapshots[snapshot.feature.id] = snapshot
        featureOrder.append(snapshot.feature)
        return snapshot
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        await recorder.record("\(identity):message:\(featureID):\(text)")
        guard let snapshot = snapshots[featureID] else { throw APIError.invalidResponse }
        return snapshot
    }

    func uploadFirstMateAttachment(featureID: String, fileURL: URL, contentType: String) async throws -> AttachmentUploadResponse {
        await recorder.record("\(identity):upload:\(featureID)")
        throw APIError.invalidResponse
    }

    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        await recorder.record("\(identity):transcribe")
        throw APIError.invalidResponse
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        await recorder.record("\(identity):action:\(featureID):\(action)")
        guard let snapshot = snapshots[featureID] else { throw APIError.invalidResponse }
        return snapshot
    }

    func setFirstMateArchived(
        featureID: String,
        archived: Bool,
        reason: FirstMateArchiveReason?,
        requestID: String
    ) async throws -> FirstMateSnapshot {
        await recorder.record("\(identity):archive:\(featureID):\(archived)")
        guard var snapshot = snapshots[featureID] else { throw APIError.invalidResponse }
        snapshot.feature.archivedAt = archived ? FirstMateDemo.timestamp : nil
        snapshot.feature.archiveReason = archived ? reason?.rawValue : nil
        snapshot.feature.revision += 1
        snapshots[featureID] = snapshot
        if let index = featureOrder.firstIndex(where: { $0.id == featureID }) {
            featureOrder[index] = snapshot.feature
        }
        return snapshot
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        await recorder.record("\(identity):document:\(id)")
        guard let document = snapshots.values.flatMap(\.documents).first(where: { $0.id == id }) else {
            throw APIError.invalidResponse
        }
        return .init(ok: true, document: document, content: document.content)
    }

    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        await recorder.record("\(identity):session:\(id)")
        guard snapshots.values.contains(where: { snapshot in
            snapshot.sessions.contains { $0.nativeSessionID == id }
        }) else { throw APIError.invalidResponse }
        return .init(
            ok: true,
            nativeSessionID: id,
            messages: [.init(role: "assistant", text: "Synthetic saved session")],
            content: nil,
            nextBefore: nil,
            totalMessages: 1
        )
    }
}

/// Gates one create request until the test releases it, so a connection
/// rotation can happen while the dialog is still in flight.
private actor RoutingGate {
    private var continuation: CheckedContinuation<FirstMateSnapshot, any Error>?
    private var requests = 0

    func create() async throws -> FirstMateSnapshot {
        requests += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForRequest() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while continuation == nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw RoutingGateError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func succeed(_ snapshot: FirstMateSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private enum RoutingGateError: Error {
    case timedOut
}
