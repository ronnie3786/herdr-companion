import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Contextual assistant") @MainActor
struct AssistantSessionTests {
    @Test("Unknown submission retains its request ID and frozen context for reconciliation")
    func uncertainSubmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var requests: [AssistantRequest] = []
        let run = try JSONDecoder().decode(HeadlessAgentRun.self, from: Data(#"{"id":"agr_0123456789ab","status":"completed","prompt":"Question","response":"Answer","createdAt":"2026-09-07T00:00:00Z"}"#.utf8))
        let transport = AssistantTransport(
            capabilities: { AssistantCapabilities(profiles: ["contextual-question-v1"]) },
            start: { request in requests.append(request); throw URLError(.networkConnectionLost) },
            fetch: { _ in run }, stop: { _ in run },
            models: { throw URLError(.notConnectedToInternet) },
            promote: { _ in run }, openAgent: { _ in }
        )
        let context = AssistantContext(source: .init(feature: "notes", instanceId: "test"),
                                       items: [.init(id: "note", kind: "note.v1", label: "Note", text: "  exact\ntext")])
        let session = AssistantSession(title: "Example", machineID: "test", paneID: nil, rootPath: nil,
                                       context: context, transport: transport,
                                       persistence: AssistantPersistence(url: folder.appendingPathComponent("question.json")))
        await session.prepare()
        session.draft = "Question"
        session.submit()
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.pending != nil)
        session.draft = "Another draft"
        session.retrySubmission()
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests.count == 2)
        #expect(requests.first?.clientRequestId == requests.last?.clientRequestId)
        #expect(requests.last?.context == context)
        #expect(session.draft == "Another draft")
        #expect(!session.canSend)
    }

    @Test("Removing context cannot mutate the captured snapshot")
    func immutableContext() throws {
        let original = AssistantContext(source: .init(feature: "notes", instanceId: "test"),
                                        items: [.init(id: "note", kind: "note.v1", label: "Note", text: "  exact\ntext")])
        let request = AssistantRequest(prompt: "Question", scope: .init(), context: original)
        var next = original
        next.items.removeAll()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AssistantRequest.self, from: data)
        #expect(decoded.context.items[0].text == "  exact\ntext")
        #expect(decoded.profile == "contextual-question-v1")
    }
}
