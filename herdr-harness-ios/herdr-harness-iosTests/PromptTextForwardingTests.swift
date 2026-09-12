import Foundation
import Testing
@testable import herdr_harness_ios

@MainActor
@Suite("Native prompt text forwarding", .serialized)
struct PromptTextForwardingTests {
    @Test("Semantic Pi submission validates but forwards exact nonblank text")
    func semanticPiSubmissionPreservesText() async throws {
        PromptTextURLProtocol.recorder.reset()
        let fixture = try makeFixture(agentStatus: .idle)
        let store = PiConversationStore()
        try await connect(store)
        let text = "\n  Preserve this indentation.\n"

        #expect(await store.submit(
            text: text,
            disposition: .prompt,
            model: fixture.model,
            pane: fixture.pane
        ))

        let request = try #require(PromptTextURLProtocol.recorder.requests().only)
        #expect(request.path == "/api/v1/panes/w1:p1/pi/prompt")
        #expect(request.body["text"] as? String == text)
    }

    @Test("Semantic Pi whitespace-only text is still rejected")
    func semanticPiWhitespaceGateRemains() async throws {
        PromptTextURLProtocol.recorder.reset()
        let fixture = try makeFixture(agentStatus: .idle)
        let store = PiConversationStore()
        try await connect(store)

        #expect(await store.submit(
            text: " \n  ",
            disposition: .prompt,
            model: fixture.model,
            pane: fixture.pane
        ) == false)
        await #expect(throws: APIError.self) {
            try await fixture.model.sendPiConversationPrompt(
                " \n  ",
                disposition: .prompt,
                to: fixture.pane
            )
        }
        #expect(PromptTextURLProtocol.recorder.requests().isEmpty)
    }

    @Test("Detected-agent prompt forwards exact nonblank text")
    func detectedAgentPromptPreservesText() async throws {
        PromptTextURLProtocol.recorder.reset()
        let fixture = try makeFixture(agentStatus: .idle)
        let text = "\n  Inspect the indented block.\n"

        #expect(await fixture.model.sendPrompt(text, to: fixture.pane))

        let request = try #require(PromptTextURLProtocol.recorder.requests().only)
        #expect(request.path == "/api/v1/panes/w1:p1/prompt")
        #expect(request.body["text"] as? String == text)
    }

    @Test("Shell submission forwards exact nonblank command text")
    func shellPromptPreservesText() async throws {
        PromptTextURLProtocol.recorder.reset()
        let fixture = try makeFixture(agentStatus: .unknown)
        let text = "  printf 'preserved'\n"

        #expect(await fixture.model.sendPrompt(text, to: fixture.pane))

        let request = try #require(PromptTextURLProtocol.recorder.requests().only)
        #expect(request.path == "/api/v1/panes/w1:p1/run")
        #expect(request.body["command"] as? String == text)
    }

    @Test("General prompt whitespace-only text is still rejected")
    func generalPromptWhitespaceGateRemains() async throws {
        PromptTextURLProtocol.recorder.reset()
        let fixture = try makeFixture(agentStatus: .idle)

        #expect(await fixture.model.sendPrompt(" \n  ", to: fixture.pane) == false)
        #expect(PromptTextURLProtocol.recorder.requests().isEmpty)
    }

    private func connect(_ store: PiConversationStore) async throws {
        let stream = AsyncThrowingStream<PiConversationStreamEvent, any Error> { continuation in
            continuation.yield(.envelope(PiConversationEnvelope(
                paneID: "w1:p1",
                sessionID: "synthetic-session",
                cursor: "1",
                event: .object([
                    "type": .string("bridge.connection"),
                    "connected": .bool(true),
                ])
            )))
            continuation.finish()
        }

        #expect(try await store.consume(stream) == false)
        #expect(store.canSendCommands)
    }

    private func makeFixture(
        agentStatus: AgentStatus
    ) throws -> (model: HerdrAppModel, pane: HerdrPane) {
        let suiteName = "PromptTextForwardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let machine = HerdrMachine(
            id: "m1",
            name: "Synthetic Mac",
            urlString: "http://localhost:9092"
        )
        let configuration = try #require(
            ServerConfiguration(urlString: machine.urlString, token: "synthetic-token")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PromptTextURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: [],
            userDefaults: defaults
        )
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live

        let rawPane = HerdrPane(
            paneID: "w1:p1",
            terminalID: "w1:p1",
            workspaceID: "w1",
            tabID: "",
            focused: true,
            agentStatus: agentStatus,
            revision: 1,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: agentStatus == .unknown ? nil : "pi",
            displayAgent: agentStatus == .unknown ? nil : "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
        model.workspaces = [HerdrWorkspace(
            workspaceID: "w1",
            number: 1,
            label: "Synthetic Workspace",
            focused: true,
            paneCount: 1,
            tabCount: 0,
            activeTabID: "",
            agentStatus: agentStatus,
            panes: [rawPane]
        ).stamped(machineID: machine.id)]
        return (model, try #require(model.pane(id: "m1|w1:p1")))
    }
}

private final class PromptTextURLProtocol: URLProtocol {
    static let recorder = PromptTextRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct PromptTextRequest {
    let path: String
    let body: [String: Any]
}

private final class PromptTextRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [PromptTextRequest] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
    }

    func record(_ request: URLRequest) {
        let body = Self.bodyData(from: request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(PromptTextRequest(
            path: request.url?.path ?? "",
            body: body
        ))
    }

    func requests() -> [PromptTextRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
