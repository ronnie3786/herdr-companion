import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Independent HUD chats", .serialized)
@MainActor
struct HerdrHudChatsTests {
    @Test("Two live chats finish independently; follow-ups, drafts and cancellation stay with their owner")
    func concurrentChats() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = fixture.chats
        let first = chats.composer
        first.draft = "Plan a garden"
        let firstTask = Task { await first.submit(model: fixture.model) { chats.submissionStarted(first) } }
        try await wait { first.thread != nil }
        #expect(first.isRunning)
        #expect(chats.composer !== first)

        let second = chats.composer
        second.draft = "Compare telescopes"
        let secondTask = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { second.thread != nil }
        let firstID = try #require(first.thread?.lastRunID)
        let secondID = try #require(second.thread?.lastRunID)
        #expect(firstID != secondID)
        #expect(chats.visibleChats.count == 2)
        #expect(first.isRunning && second.isRunning)
        chats.composer.draft = "A third idea, not sent"

        HudChatsURLProtocol.finish(secondID)
        await secondTask.value
        #expect(first.isRunning)
        #expect(second.hasUnseenAnswer)
        #expect(second.exchanges.last?.response == "Answer for Compare telescopes")
        #expect(chats.composer.draft == "A third idea, not sent")
        #expect(chats.selectedID == nil)

        let secondChat = try #require(chats.visibleChats.first { $0.session === second })
        chats.select(secondChat.id)
        second.markSeen()
        second.draft = "Which is portable?"
        let followUp = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { HudChatsURLProtocol.state.withLock { $0.starts.count == 3 } }
        try await wait { second.thread?.lastRunID != secondID }
        let followUpID = try #require(second.thread?.lastRunID)
        #expect(second.thread?.rootRunID == secondID)
        #expect(chats.visibleChats.count == 2)
        #expect(chats.composer.draft == "A third idea, not sent")
        #expect(chats.selectedID == nil)
        #expect(!second.hasUnseenAnswer)

        await first.stop(model: fixture.model)
        await firstTask.value
        #expect(first.exchanges.last?.status == .cancelled)
        #expect(second.isRunning)
        HudChatsURLProtocol.finish(followUpID)
        await followUp.value
        #expect(second.thread?.turnCount == 2)
        #expect(second.exchanges.map(\.prompt) == ["Compare telescopes", "Which is portable?"])
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.allSatisfy { $0.profile == "hud-chat-v1" } })
    }

    @Test("History reuses active roots and relaunch reattaches without another submission")
    func restorationAndHistoryDeduplication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitted = fixture.chats.composer
        submitted.draft = "Sketch a reading nook"
        let task = Task { await submitted.submit(model: fixture.model) { fixture.chats.submissionStarted(submitted) } }
        try await wait { submitted.thread != nil }
        let runID = try #require(submitted.thread?.rootRunID)
        let chatID = try #require(fixture.chats.visibleChats.first?.id)
        let summary = HudChatSummary(id: runID, title: "Reading nook", updatedAt: "2026-09-01T12:00:00Z",
                                     latestRunId: runID, turnCount: 1, status: .running, sessionId: nil, promotedPaneId: nil)
        let reopened = try await fixture.chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        #expect(reopened == chatID)
        #expect(fixture.chats.visibleChats.count == 1)

        let cache = fixture.directory.appendingPathComponent("hud-chats/\(chatID).json")
        try await wait { HerdrHudPersistenceSnapshot.load(from: cache)?.thread?.rootRunID == runID }
        let restored = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await restored.restore(model: fixture.model)
        let restoredSession = try #require(restored.visibleChats.first?.session)
        #expect(restoredSession !== submitted)
        #expect(restoredSession.isRunning)
        #expect(restoredSession.thread?.rootRunID == runID)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)

        HudChatsURLProtocol.finish(runID)
        await task.value
        try await wait { !restoredSession.isRunning }
        try await wait { restoredSession.exchanges.last?.status == .completed }
        #expect(restoredSession.hasUnseenAnswer)
        try await restored.dismiss(chatID, model: fixture.model)
        #expect(restored.visibleChats.isEmpty)
        #expect(HudChatsURLProtocol.state.withLock { $0.deleteCount } == 0)
        let afterDismiss = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        await afterDismiss.restore(model: fixture.model)
        #expect(afterDismiss.visibleChats.isEmpty)
    }

    @Test("Offline restored runs cannot submit a stale continuation")
    func offlineRestoration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Compare trail maps"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(fixture.chats.visibleChats.first?.id)
        let cache = fixture.directory.appendingPathComponent("hud-chats/\(id).json")
        try await wait { HerdrHudPersistenceSnapshot.load(from: cache)?.thread != nil }
        let restored = HerdrHudChats(legacySession: fixture.prototype, defaults: fixture.defaults)
        let cached = try #require(restored.chats.first { $0.id == id }?.session)
        await cached.waitForPersistenceRestore()
        #expect(cached.needsHistoryRefresh)
        cached.draft = "Do not duplicate this run"
        await cached.submit(model: fixture.model)
        #expect(cached.draft == "Do not duplicate this run")
        #expect(cached.validationError != nil)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
        fixture.model.machineStates["synthetic"] = .disconnected
        await #expect(throws: HerdrHudChatEndError.self) {
            try await restored.end(id, model: fixture.model)
        }
        #expect(restored.visibleChats.count == 1)
        #expect(!cached.hasEnded && !cached.isEnding)
        fixture.model.machineStates["synthetic"] = .live
        await session.stop(model: fixture.model)
        await task.value
    }

    @Test("A rejected stop keeps observing the same run instead of stranding its bubble")
    func failedCancellationKeepsObserving() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a picnic"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(session.thread?.lastRunID)
        HudChatsURLProtocol.state.withLock { $0.rejectNextCancellation = true }
        await session.stop(model: fixture.model)
        #expect(session.isRunning)
        #expect(session.errorMessage != nil)
        HudChatsURLProtocol.finish(id)
        await task.value
        #expect(session.exchanges.last?.status == .completed)
        #expect(session.hasUnseenAnswer)
    }

    @Test("A rejected start retains its own draft and does not overwrite the fresh composer")
    func failedStartKeepsItsChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let submitted = fixture.chats.composer
        submitted.draft = "Keep this idea"
        HudChatsURLProtocol.state.withLock { $0.rejectNextStart = true }
        await submitted.submit(model: fixture.model) {
            fixture.chats.submissionStarted(submitted)
            fixture.chats.composer.draft = "Another unsent idea"
        }
        #expect(fixture.chats.visibleChats.count == 1)
        #expect(submitted.exchanges.last?.status == .failed)
        #expect(submitted.draft == "Keep this idea")
        #expect(submitted.hasUnseenAnswer)
        #expect(fixture.chats.composer.draft == "Another unsent idea")
    }

    @Test("End Chat stops one run, removes only its bubble, and retains history")
    func endActiveChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = fixture.chats
        let first = chats.composer
        first.draft = "Plan a picnic"
        let firstTask = Task { await first.submit(model: fixture.model) { chats.submissionStarted(first) } }
        try await wait { first.thread != nil }
        let firstChat = try #require(chats.visibleChats.first)
        let root = try #require(first.thread?.rootRunID)
        let second = chats.composer
        second.draft = "Compare trail maps"
        let secondTask = Task { await second.submit(model: fixture.model) { chats.submissionStarted(second) } }
        try await wait { second.thread != nil }
        let secondID = try #require(chats.visibleChats.first { $0.session === second }?.id)
        chats.select(secondID)
        #expect(try await chats.end(firstChat.id, model: fixture.model) == false)
        await firstTask.value
        #expect(first.hasEnded)
        #expect(first.exchanges.last?.status == .cancelled)
        #expect(chats.selectedID == secondID)
        #expect(chats.visibleChats.count == 1)
        #expect(second.isRunning)
        #expect(HudChatsURLProtocol.state.withLock { $0.deleteCount } == 0)
        first.draft = "A stale view must not resubmit an ended chat"
        await first.submit(model: fixture.model)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 2)

        let summary = HudChatSummary(id: root, title: "Plan a picnic", updatedAt: "2026-09-01T12:00:00Z",
                                     latestRunId: root, turnCount: 1, status: .cancelled, sessionId: nil, promotedPaneId: nil)
        let reopenedID = try await chats.openHistory(summary, machineID: "synthetic", model: fixture.model)
        let reopened = try #require(chats.chats.first { $0.id == reopenedID })
        #expect(reopened.id != firstChat.id)
        #expect(!reopened.session.hasEnded)
        #expect(reopened.session.exchanges.last?.status == .cancelled)
        await second.stop(model: fixture.model)
        await secondTask.value
    }

    @Test("Failed End Chat retains the running bubble and can be retried")
    func failedEndIsRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a garden"
        let task = Task { await session.submit(model: fixture.model) { fixture.chats.submissionStarted(session) } }
        try await wait { session.thread != nil }
        let id = try #require(fixture.chats.visibleChats.first?.id)
        HudChatsURLProtocol.state.withLock { $0.rejectNextCancellation = true }
        await #expect(throws: HerdrHudChatEndError.self) {
            try await fixture.chats.end(id, model: fixture.model)
        }
        #expect(fixture.chats.visibleChats.count == 1)
        #expect(session.isRunning)
        #expect(!session.hasEnded && !session.isEnding)
        _ = try await fixture.chats.end(id, model: fixture.model)
        await task.value
        #expect(fixture.chats.visibleChats.isEmpty)
        #expect(session.hasEnded)
    }

    @Test("Ending during submission waits for its accepted identity before stopping it")
    func endDuringSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = fixture.chats.composer
        session.draft = "Plan a reading nook"
        var endTask: Task<Bool, Error>?
        await session.submit(model: fixture.model) {
            fixture.chats.submissionStarted(session)
            let id = fixture.chats.visibleChats.first!.id
            endTask = Task { try await fixture.chats.end(id, model: fixture.model) }
        }
        _ = try await #require(endTask).value
        #expect(session.hasEnded)
        #expect(session.exchanges.last?.status == .cancelled)
        #expect(fixture.chats.visibleChats.isEmpty)
        #expect(HudChatsURLProtocol.state.withLock { $0.starts.count } == 1)
    }

    @Test("Mini HUDs render running and ready states beside ordinary workspace agents")
    func renderIndependentChats() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "herdr.hud.enabled")
        let controller = HerdrHudController(userDefaults: fixture.defaults)
        let notes = HerdrHudNotesState(userDefaults: fixture.defaults,
                                      agentSettings: AgentModelSettingsStore(defaults: fixture.defaults),
                                      promptSettings: HerdrPromptSettingsStore(defaults: fixture.defaults),
                                      persistenceURL: fixture.directory.appendingPathComponent("notes.json"))
        controller.configure(model: fixture.model, session: fixture.prototype, notes: notes, fontScale: HerdrFontScaleStore())
        let chats = try #require(controller.chats)
        let first = chats.composer
        first.draft = "Plan a small courtyard garden with native plants"
        let firstTask = Task { await controller.submitChat(first, model: fixture.model) }
        try await wait { first.thread != nil }
        let second = chats.composer
        second.draft = "Compare portable telescopes for a weekend camping trip"
        let secondTask = Task { await controller.submitChat(second, model: fixture.model) }
        try await wait { second.thread != nil }
        HudChatsURLProtocol.finish(try #require(second.thread?.lastRunID))
        await secondTask.value
        let chips = [HerdrHudSessionChips.Chip(id: "synthetic|w1:p1", title: "Main project agent", status: .working,
                                             isMuted: false, since: .now, emoji: "", activity: "Running tests")]
        let stack = try await HerdrRenderHarness.render("hud-independent-chats.png", size: CGSize(width: 310, height: 420)) {
            HerdrHudSessionChipsView(model: fixture.model, session: fixture.prototype, chips: chips,
                                     overflow: 0, chatController: controller)
                .padding(20)
                .preferredColorScheme(.dark)
        }
        stack.expectSubstantial()
        let selected = try #require(chats.visibleChats.first { $0.session === second })
        chats.select(selected.id)
        let card = try await HerdrRenderHarness.render("hud-independent-chat-expanded.png", size: CGSize(width: 430, height: 600)) {
            HerdrHudCardView(model: fixture.model, controller: controller, session: second)
                .preferredColorScheme(.dark)
        }
        card.expectSubstantial()
        controller.resizeChat(to: CGSize(width: 640, height: 680))
        let larger = try await HerdrRenderHarness.render("hud-chat-resized.png",
            size: CGSize(width: controller.chatCardSize.width + 20, height: controller.chatCardSize.height + 20)) {
            HerdrHudCardView(model: fixture.model, controller: controller, session: second)
                .preferredColorScheme(.dark)
        }
        larger.expectSubstantial()
        await first.stop(model: fixture.model)
        await firstTask.value
        controller.setEnabled(false)
    }

    @Test("Independent sessions retain attachments in different directories")
    func attachmentIsolation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let source = fixture.directory.appendingPathComponent("example.txt")
        try Data("Synthetic attachment".utf8).write(to: source)
        let first = fixture.prototype.makeIndependentSession(id: UUID().uuidString)
        let second = fixture.prototype.makeIndependentSession(id: UUID().uuidString)
        first.addAttachments([source])
        second.addAttachments([source])
        let firstFile = try #require(first.pendingAttachments.first)
        let secondFile = try #require(second.pendingAttachments.first)
        #expect(firstFile.url != secondFile.url)
        first.removeAttachment(firstFile.id)
        #expect(!FileManager.default.fileExists(atPath: firstFile.url.path))
        #expect(FileManager.default.fileExists(atPath: secondFile.url.path))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }

    @MainActor
    private struct Fixture {
        let suite = "hud-chats-tests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let model: HerdrAppModel
        let prototype: HerdrHudSession
        let chats: HerdrHudChats

        init() throws {
            HudChatsURLProtocol.state.withLock { $0 = .init() }
            defaults = try #require(UserDefaults(suiteName: suite))
            prototype = HerdrHudSession(userDefaults: defaults, persistenceURL: directory.appendingPathComponent("hud-thread.json"))
            chats = HerdrHudChats(legacySession: prototype, defaults: defaults)
            let configuration = try #require(ServerConfiguration(urlString: "https://hud.example.invalid", token: "synthetic-token"))
            let urlSession = URLSessionConfiguration.ephemeral
            urlSession.protocolClasses = [HudChatsURLProtocol.self]
            let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: urlSession))
            model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults)
            let machine = HerdrMachine(id: "synthetic", name: "Example Mac", urlString: "https://hud.example.invalid")
            model.machines = [machine]
            model.clientFactory = { _ in client }
            model.prepareRuntime(for: machine, generation: model.connectionGeneration)
            model.machineStates[machine.id] = .live
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// The protocol adds no mutable instance state; synthetic server state is locked.
private final class HudChatsURLProtocol: URLProtocol {
    struct Start: Sendable {
        let id: String
        let root: String
        let prompt: String
        let profile: String
    }
    struct State: Sendable {
        var starts: [Start] = []
        var statuses: [String: String] = [:]
        var deleteCount = 0
        var rejectNextCancellation = false
        var rejectNextStart = false
    }
    static let state = Mutex(State())
    static func finish(_ id: String) { state.withLock { $0.statuses[id] = "completed" } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let body = requestBody()
        let payload = Self.state.withLock { state -> (Int, Data) in
            let path = url.path
            if path.hasSuffix("/cancel"), state.rejectNextCancellation {
                state.rejectNextCancellation = false
                return (503, Data(#"{"ok":false,"error":{"message":"Synthetic stop failure"}}"#.utf8))
            }
            if path == "/api/v1/agent-runs", request.httpMethod == "POST", state.rejectNextStart {
                state.rejectNextStart = false
                return (429, Data(#"{"ok":false,"error":{"message":"Synthetic capacity limit"}}"#.utf8))
            }
            var response: [String: Any] = ["ok": true]
            if request.httpMethod == "DELETE" { state.deleteCount += 1 }
            if path.hasSuffix("/capabilities") {
                response["profiles"] = ["hud-chat-v1"]
            } else if path == "/api/v1/agent-runs", request.httpMethod == "POST" {
                let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let id = String(format: "agr_%012d", state.starts.count + 1)
                let prior = input["continueFromRunId"] as? String
                let root = state.starts.first { $0.id == prior }?.root ?? id
                let start = Start(id: id, root: root, prompt: input["prompt"] as? String ?? "", profile: input["profile"] as? String ?? "")
                state.starts.append(start)
                state.statuses[id] = "running"
                response["run"] = Self.run(start, state: state)
            } else if path.contains("/hud-chats/"), request.httpMethod == "GET" {
                let root = url.lastPathComponent
                let turns = state.starts.filter { $0.root == root }
                response["turns"] = turns.map { Self.run($0, state: state) }
                response["rootRunId"] = root
                response["latestRunId"] = turns.last?.id ?? root
            } else if path.contains("/agent-runs/") {
                let id = path.hasSuffix("/cancel") ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
                if path.hasSuffix("/cancel") { state.statuses[id] = "cancelled" }
                if let start = state.starts.first(where: { $0.id == id }) { response["run"] = Self.run(start, state: state) }
            }
            return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
        }
        guard let response = HTTPURLResponse(url: url, statusCode: payload.0, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func run(_ start: Start, state: State) -> [String: Any] {
        var run: [String: Any] = ["id": start.id, "status": state.statuses[start.id] ?? "running",
                                  "prompt": start.prompt, "createdAt": "2026-09-01T12:00:00Z",
                                  "threadRootRunId": start.root, "sessionFile": "synthetic.jsonl"]
        if state.statuses[start.id] == "completed" { run["response"] = "Answer for \(start.prompt)" }
        return run
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
