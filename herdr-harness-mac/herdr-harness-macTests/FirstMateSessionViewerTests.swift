import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate saved agent viewer", .serialized)
@MainActor
struct FirstMateSessionViewerTests {
    static let messages: [FirstMateSessionMessage] = [
        .init(role: "user", text: "Research the API and summarize what the feature needs.", index: 0),
        .init(role: "assistant", text: "I’ll check the schema and the existing implementation.", index: 1,
              toolCalls: [.init(id: "read-schema", name: "read", arguments: .object(["path": .string("schema.graphql")]))], stopReason: "toolUse"),
        .init(role: "toolResult", text: "type Query { projects: [Project!]! }", index: 2,
              toolCallID: "read-schema", toolName: "read", isError: false),
        .init(role: "assistant", text: "The API already exposes the data this feature needs.\n\n- Reuse the existing project query.\n- Add the empty state in the client.\n- Confirm access rules before implementation.\n\nThe evidence and open questions are saved in the research report.", index: 3, stopReason: "stop")
    ]

    @Test("Tool calls collapse under Clanking while the final answer remains visible")
    func timeline() throws {
        let turns = FirstMateSessionTimeline.turns(Self.messages, sessionID: "synthetic", isRunning: false)
        let rows = PiTimelineRow.rows(for: turns, groupAllActivity: true)
        #expect(rows.count == 3)
        guard case .user = rows[0].content, case let .working(group) = rows[1].content,
              case let .output(.assistant(answer)) = rows[2].content else {
            Issue.record("Expected user bubble, Clanking group, and final response"); return
        }
        #expect(group.toolCount == 1)
        #expect(!group.isLive)
        #expect(answer.text == Self.messages.last?.text)
        let missing = FirstMateSessionTimeline.turns(Array(Self.messages.prefix(2)), sessionID: "missing", isRunning: false)
        guard case let .tool(tool) = missing[0].items.last else { Issue.record("Missing tool"); return }
        #expect(tool.status == .unavailable)
        #expect(PiTurnSegmentation.segments(for: missing[0], groupAllActivity: true).count == 1)
    }

    @Test("Running sessions refresh without losing the loaded prefix or duplicating overlapping messages")
    func refresh() async throws {
        let client = SessionViewerClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        let session = FirstMateSession(nativeSessionID: "synthetic", featureID: "feature", title: "Research Scout",
            role: "researcher", status: "running", generation: 1, createdAt: "", updatedAt: "", ownershipStatus: "managed")
        await store.open(.history(session))
        #expect(store.sessionIsRunning)
        #expect(store.sessionMessages?.count == 2)
        await store.refreshSessionMessages()
        #expect(store.sessionMessages?.map(\.index) == [0, 1, 2, 3])
        #expect(!store.sessionIsRunning)
        #expect(store.sessionMessages?.last?.text == Self.messages.last?.text)
        await store.refreshSessionMessages()
        #expect(await client.reads == 2)
        store.closeResource()
        #expect(store.sessionMessages == nil)
    }

    @Test("Read-only chat preview uses real Chat rows in both appearances", arguments: [ColorScheme.light, .dark])
    func preview(scheme: ColorScheme) async throws {
        let appearance = scheme == .light ? "light" : "dark"
        let render = try await HerdrRenderHarness.render("first-mate-agent-viewer-\(appearance).png", size: CGSize(width: 760, height: 620)) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Research Scout", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                    Text("Worker · Saved Pi conversation").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
                Divider()
                ScrollView {
                    FirstMateSessionTranscriptView(messages: Self.messages, fallbackText: "", sessionID: "synthetic")
                        .padding(24)
                }
                Divider()
                Text("Read-only saved history").font(.caption).foregroundStyle(.secondary).padding(16)
            }
            .background(FirstMatePalette(scheme: scheme).background)
            .environment(\.colorScheme, scheme)
        }
        render.expectSubstantial(minimumBytes: 8_192)
    }
}

private actor SessionViewerClient: FirstMateClient {
    var reads = 0
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse {
        reads += 1
        let messages = await FirstMateSessionViewerTests.messages
        return .init(ok: true, nativeSessionID: id,
                     messages: reads == 1 ? Array(messages.prefix(2)) : Array(messages.suffix(3)),
                     content: nil, nextBefore: nil, totalMessages: reads == 1 ? 2 : 4, isRunning: reads == 1)
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: []) }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
}
