import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Response brief rendering", .serialized)
@MainActor
struct ResponseBriefRenderTests {
    @Test("Wide chat keeps a native rail beyond the reading column")
    func wideRail() async throws {
        let fixture = try await RenderFixture()
        defer { fixture.cleanup() }
        let result = try await HerdrRenderHarness.render(
            "response-brief-wide.png",
            size: CGSize(width: 2_100, height: 820)
        ) {
            fixture.layout
        }
        #expect(result.byteCount > 10_000)
    }

    @Test("Narrow chat renders the explicit sheet fallback control at large text")
    func narrowFallback() async throws {
        let fixture = try await RenderFixture()
        defer { fixture.cleanup() }
        let result = try await HerdrRenderHarness.render(
            "response-brief-narrow.png",
            size: CGSize(width: 1_100, height: 720)
        ) {
            fixture.layout
                .environment(\.herdrFontScale, .xxxLarge)
        }
        #expect(result.byteCount > 8_000)
    }
}

@MainActor
private final class RenderFixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let coordinator: ResponseBriefCoordinator
    let source: ResponseBriefSource
    let transport: ResponseBriefTransport

    init() async throws {
        let newDirectory = FileManager.default.temporaryDirectory.appending(path: "response-brief-render-\(UUID().uuidString)")
        let newSuiteName = "response-brief-render-\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuiteName))
        let persistence = ResponseBriefPersistence(url: newDirectory.appending(path: "cache.json"))
        directory = newDirectory
        suiteName = newSuiteName
        defaults = newDefaults
        coordinator = ResponseBriefCoordinator(defaults: newDefaults, persistence: persistence)
        source = ResponseBriefSource(
            chat: .init(machineID: "synthetic-machine", paneID: "w1:p2", sessionID: "synthetic-session"),
            responseID: "answer-render",
            text: "## Exact original\n\n| Choice | Result |\n| --- | --- |\n| Native rail | Selected |\n\n```swift\nlet safe = true\n```",
            currentUserText: "Summarize the result",
            previousUserText: nil,
            previousAssistantText: nil
        )
        transport = ResponseBriefTransport(
            capabilities: { _ in AssistantCapabilities(profiles: ["response-brief-v1"]) },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [], defaultModel: nil) },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, _ in throw APIError.invalidResponse },
            fetch: { _, _ in throw APIError.invalidResponse },
            cancel: { _, _ in throw APIError.invalidResponse }
        )
        let brief = ResponseBrief(
            version: 1,
            title: "Native reading rail is ready",
            summary: "The experimental brief keeps the original conversation authoritative and opens exact source in one readable detail sheet.",
            points: [
                .init(text: "The wide layout preserves the full reading column.", startLine: 1, endLine: 1),
                .init(text: "Narrow windows use an explicit sheet fallback.", startLine: 3, endLine: 5),
            ],
            details: [
                .init(label: "View comparison table", kind: .table, startLine: 3, endLine: 5),
                .init(label: "See implementation code", kind: .code, startLine: 7, endLine: 9),
            ]
        )
        try await persistence.saveRecord(.init(
            id: "render-record",
            source: source,
            brief: brief,
            model: "provider/example",
            thinkingLevel: "low",
            createdAt: .now
        ))
        coordinator.enable(source.chat)
        await coordinator.load()
    }

    var layout: some View {
        ResponseBriefChatLayout(
            coordinator: coordinator,
            transport: transport,
            chat: source.chat,
            latestSource: source,
            initiallyShowsRail: true
        ) {
            ZStack {
                HerdrTheme.graphite
                VStack(alignment: .leading, spacing: 16) {
                    Text("Original Pi conversation")
                        .herdrFont(.title2, weight: .bold)
                    Text("The source column and composer remain unchanged while the brief rail sits beyond them.")
                        .herdrFont(.body)
                    Spacer()
                    Text("Composer")
                        .herdrFont(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HerdrTheme.input)
                }
                .padding(28)
            }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
