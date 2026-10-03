import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home bounded quick replies")
@MainActor
struct HomeQuickReplyTests {
    private func focus(_ route: HomeRoute, evidence: String = "question-1") -> HomeFocusItem {
        .init(id: "focus", title: "A question", reason: "Your input", body: "Choose a next step", route: route, fingerprint: evidence)
    }

    private func chat(_ route: HomeRoute, evidence: String = "question-1") -> HomeChatItem {
        .init(id: String(describing: route), title: "A chat", reason: "Waiting", location: "Sample", quote: "A question",
              route: route, evidenceID: evidence)
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), "Asynchronous work did not reach its expected checkpoint")
    }

    @Test("Only the focus and three visible waiting chats hydrate, with two active reads")
    func boundedHydration() async {
        let fake = QuickReplyFake()
        let feature = HomeRoute.firstMate(machineID: "alpha", featureID: "feature")
        let chats = (0..<8).map { HomeRoute.chat(paneID: "alpha::pane-\($0)") }
        ([feature] + chats).forEach { fake.add($0) }
        fake.holdReads = true
        let controller = HomeQuickReplyController(operations: fake.operations)
        let task = Task { await controller.hydrate(focus: focus(feature), chats: chats.map { chat($0) }, enabled: true) }
        await settle { fake.activeReads == 2 }
        #expect(fake.reads.count == 2)
        fake.releaseReads()
        await settle { fake.reads.count == 4 }
        fake.releaseReads()
        await task.value
        #expect(fake.maximumActiveReads == 2)
        #expect(Set(fake.reads) == Set([feature] + Array(chats.prefix(3))))
        #expect(controller.presentations.count == 4)
        #expect(fake.submissions.isEmpty)
        await controller.hydrate(focus: focus(feature), chats: chats.map { chat($0) }, enabled: true)
        #expect(fake.reads.count == 4)
    }

    @Test("Hidden Home cancels queued reads and rejects late cancellation-ignoring replies")
    func hidingCancels() async {
        let fake = QuickReplyFake()
        let routes = (0..<3).map { HomeRoute.chat(paneID: "alpha::pane-\($0)") }
        routes.forEach { fake.add($0) }
        fake.holdReads = true
        let controller = HomeQuickReplyController(operations: fake.operations)
        let task = Task { await controller.hydrate(focus: nil, chats: routes.map { chat($0) }, enabled: true) }
        await settle { fake.activeReads == 2 }
        await controller.hydrate(focus: nil, chats: [], enabled: false)
        fake.releaseReads()
        await task.value
        #expect(fake.reads.count == 2)
        #expect(controller.presentations.isEmpty)
    }

    @Test("Disappearance clears completed options and the next visit reloads them")
    func pauseAfterCompletedHydration() async {
        let fake = QuickReplyFake()
        let route = HomeRoute.chat(paneID: "alpha::pane")
        fake.add(route)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: nil, chats: [chat(route)], enabled: true)
        #expect(controller.presentations[route]?.phase == .ready)
        controller.pauseHydration()
        #expect(controller.presentations.isEmpty)
        await controller.hydrate(focus: nil, chats: [chat(route)], enabled: true)
        #expect(fake.reads.count == 2)
        #expect(controller.presentations[route]?.phase == .ready)
    }

    @Test("A changed token or generation rejects a delayed old owner even when entity IDs match")
    func replacementOwner() async {
        let fake = QuickReplyFake()
        let route = HomeRoute.firstMate(machineID: "alpha", featureID: "same")
        fake.add(route)
        fake.holdReads = true
        let controller = HomeQuickReplyController(operations: fake.operations)
        let old = Task { await controller.hydrate(focus: focus(route), chats: [], enabled: true) }
        await settle { fake.reads.count == 1 }
        fake.add(route, generation: 2, token: "replacement")
        let latest = Task { await controller.hydrate(focus: focus(route), chats: [], enabled: true) }
        await settle { fake.reads.count == 2 }
        fake.releaseReads()
        await old.value
        await latest.value
        #expect(controller.presentations[route]?.question?.owner == fake.owners[route])
        #expect(controller.presentations[route]?.question?.owner.generation == 2)
        #expect(fake.maximumActiveReads == 2)
    }

    @Test("Double click sends the exact validated label once and completion survives hiding")
    func duplicateAndHide() async throws {
        let fake = QuickReplyFake()
        let route = HomeRoute.firstMate(machineID: "alpha", featureID: "feature")
        fake.add(route)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: focus(route), chats: [], enabled: true)
        let question = try #require(controller.presentations[route]?.question)
        let action = try #require(question.actions.first)
        fake.holdSubmissions = true
        let send = Task { await controller.send(action, to: route, question: question) }
        await settle { fake.submissions.count == 1 }
        await controller.send(action, to: route, question: question)
        await controller.hydrate(focus: nil, chats: [], enabled: false)
        fake.releaseSubmissions()
        await send.value
        #expect(fake.submissions == [action.label])
        #expect(controller.presentations[route]?.phase == .accepted)
        await controller.hydrate(focus: focus(route), chats: [], enabled: true)
        #expect(controller.presentations[route]?.phase == .accepted)
        #expect(controller.presentations[route]?.actions.isEmpty == true)
    }

    @Test("Message, session, owner, and unsupported-choice changes prevent stale submission", arguments: ["message", "session", "owner", "choice"])
    func staleQuestion(change: String) async throws {
        let fake = QuickReplyFake()
        let route = HomeRoute.chat(paneID: "alpha::pane")
        fake.add(route)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: nil, chats: [chat(route)], enabled: true)
        let question = try #require(controller.presentations[route]?.question)
        let action = try #require(question.actions.first)
        switch change {
        case "message": fake.questions[route]?.messageID = "new-question"
        case "session": fake.questions[route]?.sessionID = "replacement-session"
        case "owner": fake.add(route, generation: 2)
        default: fake.questions[route]?.actions = []
        }
        await controller.send(action, to: route, question: question)
        #expect(fake.submissions.isEmpty)
    }

    @Test("Failed sends retain their owner and require an explicit retry without new submission")
    func explicitRetry() async throws {
        let fake = QuickReplyFake()
        let route = HomeRoute.firstMate(machineID: "alpha", featureID: "feature")
        fake.add(route)
        fake.sendResult = .deliveryUnconfirmed("Check delivery", retryable: true)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: focus(route), chats: [], enabled: true)
        let question = try #require(controller.presentations[route]?.question)
        let action = try #require(question.actions.first)
        await controller.send(action, to: route, question: question)
        await controller.hydrate(focus: nil, chats: [], enabled: false)
        await controller.hydrate(focus: focus(route, evidence: "updated"), chats: [], enabled: true)
        #expect(fake.submissions.count == 1 && fake.retries.isEmpty)
        #expect(controller.presentations[route]?.phase.canRetry == true)
        await controller.retry(route: route)
        #expect(fake.submissions.count == 1 && fake.retries == [question.owner])
        #expect(controller.presentations[route]?.phase == .accepted)
    }

    @Test("Replacing a connection keeps its unresolved send visible without offering new-owner choices", arguments: [false, true])
    func replacementRetainsUnresolvedSend(replaceWhileSending: Bool) async throws {
        let fake = QuickReplyFake()
        let route = HomeRoute.firstMate(machineID: "alpha", featureID: "feature")
        fake.add(route)
        fake.sendResult = .deliveryUnconfirmed("Check delivery", retryable: true)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: focus(route), chats: [], enabled: true)
        let question = try #require(controller.presentations[route]?.question)
        fake.holdSubmissions = replaceWhileSending
        let sending = Task { await controller.send(question.actions[0], to: route, question: question) }
        await settle { fake.submissions.count == 1 }
        if !replaceWhileSending { await sending.value }
        fake.add(route, generation: 2, token: "replacement")
        await controller.hydrate(focus: focus(route), chats: [], enabled: true)
        if replaceWhileSending {
            fake.releaseSubmissions()
            await sending.value
        }
        let reads = fake.reads.count
        controller.pauseHydration()
        await controller.hydrate(focus: focus(route, evidence: "replacement-question"), chats: [], enabled: true)
        #expect(fake.reads.count == reads)
        #expect(controller.presentations[route]?.question == question)
        #expect(controller.presentations[route]?.actions.isEmpty == true)
        #expect(controller.presentations[route]?.phase.canRetry == false)
        #expect(controller.presentations[route]?.phase.message?.contains("connection changed") == true)
        await controller.retry(route: route)
        #expect(fake.retries.isEmpty)
        #expect(fake.submissions.count == 1)
    }

    @Test("Uncertain Pi delivery offers no retry")
    func uncertainPi() async throws {
        let fake = QuickReplyFake()
        let route = HomeRoute.chat(paneID: "alpha::pane")
        fake.add(route)
        fake.sendResult = .deliveryUnconfirmed("Open to check", retryable: false)
        let controller = HomeQuickReplyController(operations: fake.operations)
        await controller.hydrate(focus: nil, chats: [chat(route)], enabled: true)
        let question = try #require(controller.presentations[route]?.question)
        await controller.send(question.actions[0], to: route, question: question)
        await controller.retry(route: route)
        #expect(fake.submissions.count == 1 && fake.retries.isEmpty)
        #expect(controller.presentations[route]?.phase.canRetry == false)
    }

    @Test("Only validated completed current First Mate questions produce choices")
    func firstMateEvidence() {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        snapshot.feature.status = "awaiting_direction"
        snapshot.messages = [.init(id: "question", featureID: snapshot.feature.id, role: "assistant",
                                   text: SkimReplyFixtures.reply, status: "done", createdAt: FirstMateDemo.timestamp,
                                   skim: SkimReplyFixtures.skim)]
        let owner = HomeQuickReplyOwner(route: .firstMate(machineID: "alpha", featureID: snapshot.feature.id),
                                        generation: 1, configuration: nil, isDemo: true)
        #expect(HomeQuickReplyEvidence.firstMate(snapshot, owner: owner)?.actions == SkimReplyFixtures.actions)
        snapshot.messages[0].text += " Changed source."
        #expect(HomeQuickReplyEvidence.firstMate(snapshot, owner: owner) == nil)
        snapshot.messages[0].text = SkimReplyFixtures.reply
        snapshot.messages[0].skim = nil
        #expect(HomeQuickReplyEvidence.firstMate(snapshot, owner: owner) == nil)
        snapshot.messages[0].skim = SkimReplyFixtures.skim
        snapshot.hasQueuedWork = true
        #expect(HomeQuickReplyEvidence.firstMate(snapshot, owner: owner) == nil)
        snapshot.hasQueuedWork = false
        snapshot.messages[0].role = "user"
        #expect(HomeQuickReplyEvidence.firstMate(snapshot, owner: owner) == nil)
    }

    @Test("Pi pending interactions, mismatched raw panes, and changed sessions never become generic reply actions")
    func piPermissionEvidence() throws {
        let pane: HerdrPane = try decode([
            "pane_id": "pane", "terminal_id": "term", "workspace_id": "workspace", "tab_id": "tab",
            "agent_status": "blocked", "pi_semantic": ["available": true, "connected": true,
            "protocolVersion": 1, "sessionId": "session", "capabilities": ["prompt": true]]
        ])
        let scoped = pane.stamped(machineID: "alpha")
        let owner = HomeQuickReplyOwner(route: .chat(paneID: scoped.id), generation: 1,
                                        configuration: nil, isDemo: true, sessionID: "session")
        var payload: [String: Any] = [
            "ok": true, "pane_id": "pane", "available": true, "connected": true,
            "session": ["id": "session"], "state": ["isStreaming": false],
            "entries": [["type": "message", "id": "answer", "message": ["role": "assistant",
                "content": [["type": "text", "text": SkimReplyFixtures.reply]], "stopReason": "stop"]]],
            "pending_interactions": [], "truncated": false
        ]
        let ready: PiConversationSnapshot = try decode(payload)
        let source = try #require(HomeQuickReplyEvidence.piSource(ready, pane: scoped, owner: owner))
        #expect(HomeQuickReplyEvidence.piQuestion(source: source, skim: SkimReplyFixtures.skim, owner: owner)?.actions == SkimReplyFixtures.actions)
        payload["pending_interactions"] = [["id": "permission", "method": "confirm", "title": "Allow once?"]]
        let permission: PiConversationSnapshot = try decode(payload)
        #expect(HomeQuickReplyEvidence.piSource(permission, pane: scoped, owner: owner) == nil)
        payload["pending_interactions"] = []
        payload["pane_id"] = "other-pane"
        let otherPane: PiConversationSnapshot = try decode(payload)
        #expect(HomeQuickReplyEvidence.piSource(otherPane, pane: scoped, owner: owner) == nil)
        payload["pane_id"] = "pane"
        payload["session"] = ["id": "other-session"]
        let otherSession: PiConversationSnapshot = try decode(payload)
        #expect(HomeQuickReplyEvidence.piSource(otherSession, pane: scoped, owner: owner) == nil)
    }

    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
private final class QuickReplyFake {
    var owners: [HomeRoute: HomeQuickReplyOwner] = [:]
    var questions: [HomeRoute: HomeQuickReplyQuestion] = [:]
    var reads: [HomeRoute] = []
    var activeReads = 0
    var maximumActiveReads = 0
    var holdReads = false
    var holdSubmissions = false
    var submissions: [String] = []
    var retries: [HomeQuickReplyOwner] = []
    var sendResult = HomeQuickReplyResult.accepted
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    func add(_ route: HomeRoute, generation: Int = 1, token: String = "synthetic") {
        let owner = HomeQuickReplyOwner(route: route, generation: generation,
                                        configuration: ServerConfiguration(urlString: "https://example.invalid", token: token),
                                        isDemo: false, sessionID: "session")
        owners[route] = owner
        questions[route] = .init(owner: owner, messageID: "question", reply: SkimReplyFixtures.reply,
                                  sessionID: "session", actions: SkimReplyFixtures.actions)
    }

    var operations: HomeQuickReplyOperations {
        .init(owner: { self.owners[$0] }, load: { owner in
            let question = self.questions[owner.route]
            self.reads.append(owner.route)
            self.activeReads += 1
            self.maximumActiveReads = max(self.maximumActiveReads, self.activeReads)
            if self.holdReads { await withCheckedContinuation { self.readWaiters.append($0) } }
            self.activeReads -= 1
            return .init(question: question)
        }, submit: { _, action in
            self.submissions.append(action.label)
            if self.holdSubmissions { await withCheckedContinuation { self.sendWaiters.append($0) } }
            return self.sendResult
        }, retry: { owner in
            self.retries.append(owner)
            return .accepted
        })
    }

    func releaseReads() {
        let waiters = readWaiters
        readWaiters = []
        waiters.forEach { $0.resume() }
    }

    func releaseSubmissions() {
        let waiters = sendWaiters
        sendWaiters = []
        waiters.forEach { $0.resume() }
    }
}
