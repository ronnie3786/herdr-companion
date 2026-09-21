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

        let visible = ResponseBriefCardView.defaultVisibleGeneratedStrings(for: fixture.record)
        #expect(visible == [
            fixture.record.brief.summary,
            fixture.record.brief.details[0].label,
            fixture.record.brief.details[1].label,
        ])
        #expect(!visible.contains(fixture.record.brief.title))
        #expect(!visible.contains(fixture.record.source.responseID))
        let policy = ResponseBriefConcisionPolicy(source: fixture.record.source.text)
        #expect(ResponseBriefConcisionPolicy.wordCount(visible.joined(separator: " ")) <= policy.metrics.maximumVisibleWords)
        #expect(ResponseBriefConcisionPolicy.nonWhitespaceScalarCount(visible.joined(separator: " ")) <= policy.metrics.maximumVisibleCharacters)
        #expect(ResponseBriefConcisionPolicy.wordCount(fixture.record.source.text) >= 100)
        #expect(ResponseBriefConcisionPolicy.wordCount(fixture.record.source.text) <= 150)
        #expect(fixture.record.brief.sourceSlice(startLine: 5, endLine: 8, source: fixture.record.source.text) == "| Finding | Status | Evidence |\n| --- | --- | --- |\n| Offline draft recovery | Passed | Restored three synthetic drafts after relaunch |\n| Export filename sanitization | Needs follow-up | Slashes still require replacement |")
        #expect(fixture.record.brief.sourceSlice(startLine: 12, endLine: 15, source: fixture.record.source.text) == "```swift\nlet safeName = proposedName.replacingOccurrences(of: \"/\", with: \"-\")\nlet preservesDraft = restoredDraft.text == originalDraft.text\n```")

        let skippedLatest = ResponseBriefSource(
            chat: fixture.source.chat,
            responseID: "answer-already-concise",
            text: "Already concise.",
            currentUserText: nil,
            previousUserText: nil,
            previousAssistantText: nil
        )
        #expect(ResponseBriefRailView.latestRecord(in: [fixture.record], for: skippedLatest) == nil)
    }

    @Test("A newly eligible short latest answer renders its own card beside prior history")
    func shortLatestGeneratesAndRenders() async throws {
        let fixture = try await ShortLatestRenderFixture()
        defer { fixture.cleanup() }
        let result = try await HerdrRenderHarness.render(
            "response-brief-short-latest.png",
            size: CGSize(width: 440, height: 760)
        ) {
            fixture.layout
        }

        #expect(result.byteCount > 6_000)
        #expect(fixture.coordinator.length == .minimal)
        #expect(fixture.coordinator.state(for: fixture.latestSource.chat).phase == .idle)
        let records = fixture.coordinator.briefs(for: fixture.latestSource.chat)
        #expect(records.count == 2)
        #expect(ResponseBriefRailView.latestRecord(in: records, for: fixture.latestSource)?.source.id == fixture.latestSource.id)
        #expect(ResponseBriefRailView.shouldShowRecordPicker(records: records, latestSource: fixture.latestSource))
        #expect(ResponseBriefCardView.defaultVisibleGeneratedStrings(for: fixture.priorRecord).isEmpty)
        #expect(ResponseBriefRailView.selectedRecordPresentation(for: fixture.priorRecord) == .regenerateNeeded)
    }

    @Test("A generated short latest card renders in the narrow large-text layout")
    func shortLatestLargeTextRendering() async throws {
        let fixture = try await ShortLatestRenderFixture()
        defer { fixture.cleanup() }
        let latestRecord = try #require(
            ResponseBriefRailView.latestRecord(
                in: fixture.coordinator.briefs(for: fixture.latestSource.chat),
                for: fixture.latestSource
            )
        )

        let result = try await HerdrRenderHarness.render(
            "response-brief-length-large-text.png",
            size: CGSize(width: 1_100, height: 720)
        ) {
            fixture.layout
                .environment(\.herdrFontScale, .xxxLarge)
        }

        #expect(result.byteCount > 8_000)
        #expect(ResponseBriefRailView.selectedRecord(
            in: [latestRecord],
            selectedRecordID: latestRecord.id,
            followsLatest: false,
            latestSource: fixture.latestSource
        ) == latestRecord)
        #expect(ResponseBriefRailView.selectionFollowsLatest(
            recordID: latestRecord.id,
            records: [latestRecord],
            latestSource: fixture.latestSource
        ))
    }

    @Test("Presentation ownership and same-source generation selection remain explicit")
    func presentationOwnershipAndSelectionDecisions() async throws {
        let fixture = try await RenderFixture()
        defer { fixture.cleanup() }
        let record = fixture.record

        #expect(ResponseBriefRailView.stateTakesPrecedence(
            .init(sourceID: record.source.id, phase: .checkingSupport),
            over: record
        ))
        #expect(ResponseBriefRailView.stateTakesPrecedence(
            .init(sourceID: record.source.id, phase: .generating),
            over: record
        ))
        #expect(ResponseBriefRailView.stateTakesPrecedence(
            .init(sourceID: record.source.id, phase: .failed("Synthetic ambiguity")),
            over: record
        ))

        let otherSource = ResponseBriefSource(
            chat: record.source.chat,
            responseID: "answer-other",
            text: record.source.text,
            currentUserText: nil,
            previousUserText: nil,
            previousAssistantText: nil
        )
        #expect(ResponseBriefRailView.shouldShowStateAlongside(
            .init(sourceID: otherSource.id, phase: .generating),
            record: record
        ))

        let shortRecord = ResponseBriefPersistence.Record(
            id: "short-record",
            source: ResponseBriefSource(
                chat: record.source.chat,
                responseID: "answer-short-history",
                text: "The synthetic review passed with one documented caveat.",
                currentUserText: nil,
                previousUserText: nil,
                previousAssistantText: nil
            ),
            brief: record.brief,
            model: record.model,
            thinkingLevel: record.thinkingLevel,
            createdAt: record.createdAt
        )
        let latestShort = try #require(ResponseBriefRailView.selectedRecord(
            in: [shortRecord],
            selectedRecordID: nil,
            followsLatest: true,
            latestSource: shortRecord.source
        ))
        let explicitlySelectedShort = try #require(ResponseBriefRailView.selectedRecord(
            in: [shortRecord],
            selectedRecordID: shortRecord.id,
            followsLatest: false,
            latestSource: record.source
        ))
        #expect(ResponseBriefRailView.selectedRecordPresentation(for: latestShort) == .regenerateNeeded)
        #expect(ResponseBriefRailView.selectedRecordPresentation(for: explicitlySelectedShort) == .regenerateNeeded)

        let newest = ResponseBriefPersistence.Record(
            id: "newest-same-source",
            source: record.source,
            brief: record.brief,
            model: record.model,
            thinkingLevel: record.thinkingLevel,
            createdAt: record.createdAt.addingTimeInterval(1)
        )
        let records = [newest, record]
        #expect(ResponseBriefRailView.selectionFollowsLatest(
            recordID: newest.id,
            records: records,
            latestSource: record.source
        ))
        #expect(!ResponseBriefRailView.selectionFollowsLatest(
            recordID: record.id,
            records: records,
            latestSource: record.source
        ))
        #expect(ResponseBriefRailView.selectedRecord(
            in: records,
            selectedRecordID: record.id,
            followsLatest: false,
            latestSource: record.source
        )?.id == record.id)
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
private final class ShortLatestRenderFixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let coordinator: ResponseBriefCoordinator
    let latestSource: ResponseBriefSource
    let priorRecord: ResponseBriefPersistence.Record
    let transport: ResponseBriefTransport

    init() async throws {
        let newDirectory = FileManager.default.temporaryDirectory.appending(path: "response-brief-short-latest-render-\(UUID().uuidString)")
        let newSuiteName = "response-brief-short-latest-render-\(UUID().uuidString)"
        let newDefaults = try #require(UserDefaults(suiteName: newSuiteName))
        let persistence = ResponseBriefPersistence(url: newDirectory.appending(path: "cache.json"))
        let chat = ResponseBriefChatIdentity(
            machineID: "synthetic-machine",
            paneID: "w1:p2",
            sessionID: "synthetic-short-session"
        )
        let priorSource = ResponseBriefSource(
            chat: chat,
            responseID: "answer-prior-verbose",
            text: Array(repeating: "Synthetic prior detail remains available.", count: 30).joined(separator: " "),
            currentUserText: nil,
            previousUserText: nil,
            previousAssistantText: nil
        )
        let verboseBrief = ResponseBrief(
            version: 1,
            title: "Compatibility title",
            summary: "This old generated card repeats its source instead of reducing reading.",
            points: [
                .init(text: "First repeated point.", startLine: 1, endLine: 1),
                .init(text: "Second repeated point.", startLine: 1, endLine: 1),
            ],
            details: []
        )
        let record = ResponseBriefPersistence.Record(
            id: "prior-verbose-record",
            source: priorSource,
            brief: verboseBrief,
            model: "provider/example",
            thinkingLevel: "low",
            createdAt: .now
        )
        let latest = ResponseBriefSource(
            chat: chat,
            responseID: "answer-short-latest",
            text: "Already concise.",
            currentUserText: nil,
            previousUserText: nil,
            previousAssistantText: nil
        )
        let syntheticTransport = ResponseBriefTransport(
            capabilities: { _ in
                AssistantCapabilities(
                    profiles: ["response-brief-v1"],
                    responseBriefs: .init(
                        version: 1,
                        lengthPolicyVersion: ResponseBriefLength.policyVersion,
                        lengthOptions: ResponseBriefLength.options
                    )
                )
            },
            models: { _ in AgentModelCatalogResponse(ok: true, models: [], defaultModel: nil) },
            fetchSnapshot: { _ in throw APIError.invalidResponse },
            start: { _, _ in syntheticShortBriefRun() },
            fetch: { _, _ in syntheticShortBriefRun() },
            cancel: { _, _ in throw APIError.invalidResponse }
        )

        directory = newDirectory
        suiteName = newSuiteName
        defaults = newDefaults
        coordinator = ResponseBriefCoordinator(defaults: newDefaults, persistence: persistence)
        latestSource = latest
        priorRecord = record
        transport = syntheticTransport

        try await persistence.saveRecord(record)
        #expect(coordinator.enable(chat))
        await coordinator.observe(latest, transport: syntheticTransport)
        await coordinator.waitForIdleForTesting()
    }

    var layout: some View {
        ResponseBriefRailView(
            coordinator: coordinator,
            transport: transport,
            chat: latestSource.chat,
            latestSource: latestSource,
            close: nil
        )
        .frame(width: 420, height: 700)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func syntheticShortBriefRun() -> HeadlessAgentRun {
    HeadlessAgentRun(
        id: "agr_synthetic0001",
        status: .completed,
        mode: .ask,
        model: nil,
        thinkingLevel: nil,
        prompt: "synthetic",
        cwd: nil,
        response: #"{"version":1,"title":"T","summary":"Answered.","points":[],"details":[]}"#,
        error: nil,
        createdAt: "2026-09-17T00:00:00Z",
        startedAt: "2026-09-17T00:00:00Z",
        finishedAt: "2026-09-17T00:00:01Z",
        sessionID: "synthetic-brief-session",
        sessionFile: nil,
        costUSD: 0,
        promotedWorkspaceID: nil,
        promotedPaneID: nil,
        attachments: nil,
        steps: nil,
        stepsTruncated: nil,
        threadRootRunId: nil
    )
}

@MainActor
private final class RenderFixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let coordinator: ResponseBriefCoordinator
    let source: ResponseBriefSource
    let record: ResponseBriefPersistence.Record
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
        let newSource = ResponseBriefSource(
            chat: .init(machineID: "synthetic-machine", paneID: "w1:p2", sessionID: "synthetic-session"),
            responseID: "answer-render",
            text: """
            ## Synthetic release review

            The Aurora Notes team reviewed the desktop release candidate after adding offline draft recovery and safer export handling. The review focused on preserving unsent work, producing predictable filenames, and keeping the rollout reversible for the fictional pilot group.

            | Finding | Status | Evidence |
            | --- | --- | --- |
            | Offline draft recovery | Passed | Restored three synthetic drafts after relaunch |
            | Export filename sanitization | Needs follow-up | Slashes still require replacement |

            The key caveat is export naming: files with slash characters can still create confusing nested paths. The candidate should not ship until sanitization is applied and the focused export check passes.

            ```swift
            let safeName = proposedName.replacingOccurrences(of: "/", with: "-")
            let preservesDraft = restoredDraft.text == originalDraft.text
            ```

            Reviewers confirmed the fallback leaves the original draft untouched, a feature flag disables the new path, and the support note explains local-copy recovery.

            Next, the fictional team will land the fix, repeat focused checks, and record the release decision.
            """,
            currentUserText: "Summarize the result",
            previousUserText: nil,
            previousAssistantText: nil
        )
        source = newSource
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
            title: "Synthetic release review",
            summary: "Hold the release: export naming still needs sanitization and a focused check.",
            points: [],
            details: [
                .init(label: "Open findings table", kind: .table, startLine: 5, endLine: 8),
                .init(label: "Inspect sample fix", kind: .code, startLine: 12, endLine: 15),
            ]
        )
        record = ResponseBriefPersistence.Record(
            id: "render-record",
            source: newSource,
            brief: brief,
            model: "provider/example",
            thinkingLevel: "low",
            createdAt: .now
        )
        try await persistence.saveRecord(record)
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
            VStack(spacing: 0) {
                ScrollView {
                    PiMarkdownMessageView(
                        source: source.text,
                        isStreaming: false,
                        detectsPaneLinks: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                Divider().overlay(HerdrTheme.separator)
                Text("Composer")
                    .herdrFont(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.input)
            }
            .background(HerdrTheme.graphite)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
