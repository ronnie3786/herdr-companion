import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
import Vision
@testable import herdr_harness_mac

/// Regression coverage for issue #41: the collapsed HUD chat bubble copies the
/// ordinary agent-session bubble's status and metadata presentation, keeps its
/// own HUD chat header, and never shows a machine name.
@Suite("HUD chat bubble presentation", .serialized)
@MainActor
struct HerdrHudChatBubbleTests {
    @Test("A healthy running HUD chat matches the agent bubble's status row")
    func runningMatchesAgentBubble() {
        let status = HerdrHudChatBubblePresentation.status(.init(isRunning: true))
        let agent = HerdrHudSessionChips.Chip(
            id: "synthetic|w1:p1",
            title: "Synthetic agent",
            status: .working,
            isMuted: false,
            since: nil
        )
        #expect(status.label == "Running")
        #expect(status.label == agent.statusLabel)
        #expect(status.symbol == "bolt.circle.fill")
        #expect(status.symbol == agent.statusSymbol)
        #expect(status.color == AgentStatus.working.color)
        #expect(status.color == agent.status.color)
    }

    @Test("Lifecycle labels keep their precedence and distinct semantics")
    func lifecycleStates() {
        func status(_ state: HerdrHudChatBubblePresentation.State) -> HerdrHudChatBubblePresentation.Status {
            HerdrHudChatBubblePresentation.status(state)
        }

        #expect(status(.init(isEnding: true, isRunning: true, hasRunError: true, lastStatus: .running))
            == .init(label: "Ending…", symbol: "stop.circle", color: HerdrTheme.mist))
        #expect(status(.init(isLoadingHistory: true, needsHistoryRefresh: true, isRunning: true, lastStatus: .failed))
            == .init(label: "Loading…", symbol: "arrow.trianglehead.2.clockwise", color: HerdrTheme.accent))
        #expect(status(.init(needsHistoryRefresh: true, isRunning: true, lastStatus: .failed))
            == .init(label: "Reconnect to check status", symbol: "wifi.exclamationmark", color: HerdrTheme.accent))
        #expect(status(.init(isRunning: true, hasRunError: true, lastStatus: .running))
            == .init(label: "Reconnecting…", symbol: "wifi.exclamationmark", color: HerdrTheme.warning))
        #expect(status(.init(isPromoting: true, lastStatus: .completed))
            == .init(label: "Continuing in agent…", symbol: "arrow.up.forward.square", color: HerdrTheme.accent))
        #expect(status(.init(lastStatus: .failed))
            == .init(label: "Needs attention", symbol: "exclamationmark.circle.fill", color: HerdrTheme.alert))
        #expect(status(.init(lastStatus: .cancelled))
            == .init(label: "Stopped", symbol: "stop.circle", color: HerdrTheme.mist))
        #expect(status(.init(lastStatus: .promoted))
            == .init(label: "In workspace", symbol: "arrow.up.forward.square", color: HerdrTheme.mist))
        #expect(status(.init(lastStatus: .completed, hasUnseenAnswer: true))
            == .init(label: "Ready", symbol: "checkmark.circle.fill", color: HerdrTheme.success))
        #expect(status(.init(lastStatus: .completed))
            == .init(label: "Done", symbol: "checkmark.circle.fill", color: HerdrTheme.mist))
        #expect(status(.init(lastStatus: .queued))
            == .init(label: "HUD chat", symbol: "checkmark.circle.fill", color: HerdrTheme.mist))
        #expect(status(.init())
            == .init(label: "HUD chat", symbol: "checkmark.circle.fill", color: HerdrTheme.mist))
    }

    @Test("Running chrome stays neutral and the unread Ready signal remains")
    func chromePolicy() {
        #expect(HerdrHudChatBubblePresentation.outlineColor(isReady: false) == HerdrTheme.accent.opacity(0.45))
        #expect(HerdrHudChatBubblePresentation.shadowColor(isReady: false) == Color.clear)
        #expect(HerdrHudChatBubblePresentation.outlineColor(isReady: true) == HerdrTheme.success)
        #expect(HerdrHudChatBubblePresentation.shadowColor(isReady: true) == HerdrTheme.success.opacity(0.3))
        #expect(HerdrHudChatBubblePresentation.cornerRadius == 10)
        #expect(HerdrHudChatBubblePresentation.horizontalPadding == 9)
        #expect(HerdrHudChatBubblePresentation.verticalPadding == 6)
        #expect(HerdrHudChatBubblePresentation.shadowRadius == 4)
        #expect(!HerdrHudChatBubblePresentation.isReady(.init(isRunning: true, lastStatus: .completed, hasUnseenAnswer: true)))
        #expect(HerdrHudChatBubblePresentation.isReady(.init(lastStatus: .completed, hasUnseenAnswer: true)))
        #expect(!HerdrHudChatBubblePresentation.isReady(.init(lastStatus: .running, hasUnseenAnswer: true)))
    }

    @Test("Metadata keeps both values for accessibility and never invents a missing one")
    func metadataPolicy() {
        let both = HerdrHudSessionMetadata(modelName: "Sonnet 4.5", cost: "$0.37")
        #expect(both.label(showsModel: true) == "Sonnet 4.5")
        #expect(both.label(showsModel: false) == "$0.37")
        #expect(both.accessibilitySummary.contains("model Sonnet 4.5"))
        #expect(both.accessibilitySummary.contains("session cost $0.37"))
        #expect(HerdrHudSessionMetadata().label(showsModel: true) == nil)
        #expect(HerdrHudSessionMetadata().label(showsModel: false) == nil)
        #expect(HerdrHudSessionMetadata(modelName: "Sonnet 4.5").label(showsModel: false) == "Cost …")
        #expect(HerdrHudSessionMetadata(cost: "$0.37").label(showsModel: true) == "Model …")
    }

    @Test("A running HUD chat sits beside a running agent bubble in both metadata phases",
          arguments: [false, true])
    func rendersRunningBubbleBesideAgent(showsModel: Bool) async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        try await fixture.startRunningChat()

        let chat = HerdrHudChats.Chat(
            id: "running-chat",
            title: "Plan the synthetic garden",
            session: fixture.session
        )
        let agent = HerdrHudSessionChips.Chip(
            id: "synthetic|w1:p1",
            title: "Plan the synthetic garden",
            status: .working,
            isMuted: false,
            since: nil,
            emoji: "",
            activity: "Running tests"
        )
        let metadata = HerdrHudSessionMetadata(modelName: "Sonnet 4.5", cost: "$0.37")
        let render = try await HerdrRenderHarness.render(
            showsModel ? "issue41-hud-chat-agent-model.png" : "issue41-hud-chat-agent-cost.png",
            size: CGSize(width: HerdrHudPlacement.chipWidth + 32, height: 300)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HerdrHudSessionBubbleLabel(chip: agent, metadata: metadata)
                HerdrHudChatBubbleView(chat: chat, model: fixture.model, controller: fixture.controller)
            }
            .padding(16)
            .environment(\.herdrHudShowsModel, showsModel)
        }
        render.expectSubstantial(minimumBytes: 3_000)

        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains("Running"))
        #expect(visible.contains(showsModel ? "Sonnet 4.5" : "$0.37"))
        #expect(!visible.contains("Example Mac"))
        await fixture.stop()
    }

    @Test("A failed chat renders its distinct Needs attention state without inventing metadata")
    func failedState() async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        let chat = try await restoredChat(
            modelName: nil,
            costUSD: nil,
            hasUnseenAnswer: false,
            exchangeStatus: .failed,
            in: fixture,
            persistenceName: "failed-state"
        )
        let render = try await renderBubble(
            chat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-failed-state.png"
        )
        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains("Needs attention"))
        #expect(!visible.contains("Model …"))
        #expect(!visible.contains("Cost …"))
        #expect(!visible.contains("Example Mac"))

        let bitmap = try bitmap(of: render)
        let (top, bottom) = verticalHalves(of: bitmap)
        #expect(min(yellowishPixelCount(bitmap, rows: top), yellowishPixelCount(bitmap, rows: bottom)) == 0)
        #expect(min(greenishPixelCount(bitmap, rows: top), greenishPixelCount(bitmap, rows: bottom)) == 0)
    }

    @Test("An unread Ready bubble keeps its green chrome and shows only its header and status when data is missing")
    func readyWithoutMetadata() async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        let chat = try await restoredChat(
            modelName: nil,
            costUSD: nil,
            hasUnseenAnswer: true,
            in: fixture,
            persistenceName: "ready-missing"
        )
        let render = try await renderBubble(
            chat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-ready-missing.png"
        )
        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains("Ready"))
        #expect(!visible.contains("Model …"))
        #expect(!visible.contains("Cost …"))
        #expect(!visible.contains("Example Mac"))

        let bitmap = try bitmap(of: render)
        let (top, bottom) = verticalHalves(of: bitmap)
        #expect(min(yellowishPixelCount(bitmap, rows: top), yellowishPixelCount(bitmap, rows: bottom)) == 0)
        #expect(min(greenishPixelCount(bitmap, rows: top), greenishPixelCount(bitmap, rows: bottom)) > 20)
    }

    @Test("Running and finished bubbles share the same neutral outline")
    func neutralRunningOutline() async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        try await fixture.startRunningChat()
        let runningChat = HerdrHudChats.Chat(
            id: "running-chat",
            title: "Plan the synthetic garden",
            session: fixture.session
        )
        let running = try await renderBubble(
            runningChat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-running-outline.png"
        )
        let runningBitmap = try bitmap(of: running)
        let (runningTop, runningBottom) = verticalHalves(of: runningBitmap)
        let runningYellowTop = yellowishPixelCount(runningBitmap, rows: runningTop)
        let runningYellowBottom = yellowishPixelCount(runningBitmap, rows: runningBottom)
        // The running status row is amber in one half; a yellow border would
        // put amber pixels in both.
        #expect(min(runningYellowTop, runningYellowBottom) == 0)
        #expect(max(runningYellowTop, runningYellowBottom) > 0)
        #expect(min(greenishPixelCount(runningBitmap, rows: runningTop), greenishPixelCount(runningBitmap, rows: runningBottom)) == 0)
        await fixture.stop()

        let doneChat = try await restoredChat(
            modelName: "Sonnet 4.5",
            costUSD: 0.37,
            hasUnseenAnswer: false,
            in: fixture,
            persistenceName: "done-neutral"
        )
        let done = try await renderBubble(
            doneChat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-done-outline.png"
        )
        let doneBitmap = try bitmap(of: done)
        let (doneTop, doneBottom) = verticalHalves(of: doneBitmap)
        #expect(min(yellowishPixelCount(doneBitmap, rows: doneTop), yellowishPixelCount(doneBitmap, rows: doneBottom)) == 0)
        #expect(min(greenishPixelCount(doneBitmap, rows: doneTop), greenishPixelCount(doneBitmap, rows: doneBottom)) == 0)
    }

    @Test("The HUD chat header stays visible when session titles are hidden",
          arguments: [HerdrFontScale.medium, .xxxLarge])
    func hiddenTitles(scale: HerdrFontScale) async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        fixture.model.showSessionTitles = false
        let chat = try await restoredChat(
            modelName: "Sonnet 4.5",
            costUSD: 0.37,
            hasUnseenAnswer: true,
            title: "Hidden title marker for the synthetic garden",
            in: fixture,
            persistenceName: "hidden-title"
        )
        let render = try await renderBubble(
            chat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-hidden-title-\(scale.label).png",
            scale: scale
        )
        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains("Ready"))
        #expect(!visible.contains("Hidden title marker"))
    }

    @Test("Long titles and model names never squeeze the status row out of its bubble",
          arguments: [HerdrFontScale.medium, .xxxLarge])
    func longContent(scale: HerdrFontScale) async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        let chat = try await restoredChat(
            modelName: "Synthetic Extremely Long Model Name For Overflow Coverage",
            costUSD: 1.24,
            hasUnseenAnswer: true,
            title: "Plan the synthetic garden for a coastal cabin with native plants and a seasonal irrigation schedule",
            in: fixture,
            persistenceName: "long-content"
        )
        let render = try await renderBubble(
            chat,
            model: fixture.model,
            controller: fixture.controller,
            name: "issue41-hud-chat-long-content-\(scale.label).png",
            scale: scale,
            size: CGSize(width: HerdrHudPlacement.chipWidth + 16, height: 180)
        )
        render.expectSubstantial(minimumBytes: 2_000)
        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains("Ready"))
        #expect(!visible.contains("Example Mac"))
    }

    @Test("Reduced motion keeps the HUD chat metadata phase visible", arguments: [false, true])
    func reducedMotion(showsModel: Bool) async throws {
        let fixture = try RunningChatFixture()
        defer { fixture.cleanUp() }
        let chat = try await restoredChat(
            modelName: "Sonnet 4.5",
            costUSD: 0.37,
            hasUnseenAnswer: true,
            in: fixture,
            persistenceName: "reduce-motion"
        )
        let render = try await renderBubble(
            chat,
            model: fixture.model,
            controller: fixture.controller,
            name: showsModel ? "issue41-hud-chat-reduce-motion-model.png" : "issue41-hud-chat-reduce-motion-cost.png",
            showsModel: showsModel,
            reduceMotion: true
        )
        let visible = try recognizedText(in: render.url)
        #expect(visible.contains("HUD chat"))
        #expect(visible.contains(showsModel ? "Sonnet 4.5" : "$0.37"))
    }
}

// MARK: - Render helpers

private extension HerdrHudChatBubbleTests {
    func renderBubble(
        _ chat: HerdrHudChats.Chat,
        model: HerdrAppModel,
        controller: HerdrHudController,
        name: String,
        showsModel: Bool = true,
        scale: HerdrFontScale = .medium,
        reduceMotion: Bool = false,
        size: CGSize = CGSize(width: HerdrHudPlacement.chipWidth + 16, height: 168)
    ) async throws -> HerdrRenderHarness.RenderResult {
        try await HerdrRenderHarness.render(name, size: size) {
            HerdrHudChatBubbleView(chat: chat, model: model, controller: controller)
                .padding(8)
                .environment(\.herdrHudShowsModel, showsModel)
                .environment(\.herdrFontScale, scale)
                .environment(\.accessibilityReduceMotion, reduceMotion)
        }
    }

    func recognizedText(in url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, url: url)
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    func bitmap(of render: HerdrRenderHarness.RenderResult) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(data: Data(contentsOf: render.url)))
    }

    /// A working-only outline or glow would paint amber pixels along every
    /// edge of the bubble, so both vertical halves would contain them. The
    /// neutral outline is lavender (blue-dominant) and the only other amber
    /// source is the running status row itself, which sits in one half.
    func yellowishPixelCount(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var count = 0
        for y in rows {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = color.redComponent
                if red > 0.18, red - color.greenComponent > 0.02, red - color.blueComponent > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The unread Ready outline and its static glow are green (green-dominant)
    /// and, unlike a status row, surround the whole bubble.
    func greenishPixelCount(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var count = 0
        for y in rows {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let green = color.greenComponent
                if green > 0.18, green - color.redComponent > 0.04, green - color.blueComponent > 0.04 {
                    count += 1
                }
            }
        }
        return count
    }

    func verticalHalves(of bitmap: NSBitmapImageRep) -> (Range<Int>, Range<Int>) {
        let middle = bitmap.pixelsHigh / 2
        return (0..<middle, middle..<bitmap.pixelsHigh)
    }
}

// MARK: - Fixtures

/// Builds a deterministic running HUD chat from the existing start/poll shapes
/// without reaching a real companion.
@MainActor
private final class RunningChatFixture {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let model: HerdrAppModel
    let session: HerdrHudSession
    let controller: HerdrHudController
    private var submitTask: Task<Void, Never>?

    init() throws {
        suiteName = "HerdrHudChatBubbleTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RunningChatURLProtocol.reset()
        session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: directory.appendingPathComponent("hud-thread.json")
        )
        controller = HerdrHudController(userDefaults: defaults)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunningChatURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults)
        let machine = HerdrMachine(id: "synthetic", name: "Example Mac", urlString: "https://hud.example.invalid")
        model.machines = [machine]
        model.clientFactory = { HerdrAPIClient(configuration: $0, session: urlSession) }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        session.selectedMachineID = machine.id
    }

    func startRunningChat() async throws {
        session.draft = "Plan the synthetic garden"
        submitTask = Task { await session.submit(model: model) }
        for _ in 0..<300 {
            if session.isRunning, session.thread != nil, session.bubbleMetadata.cost == "$0.37" {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RunningChatFixtureError.timedOut
    }

    func stop() async {
        await session.stop(model: model)
        await submitTask?.value
        submitTask = nil
    }

    func cleanUp() {
        submitTask?.cancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum RunningChatFixtureError: Error { case timedOut }

/// Restores a chat from the same version-1 snapshot the app writes, so the
/// bubble reads the accumulated metadata rather than a live run.
@MainActor
private func restoredChat(
    modelName: String?,
    costUSD: Double?,
    hasUnseenAnswer: Bool,
    exchangeStatus: HeadlessAgentRunStatus = .completed,
    title: String = "Plan the synthetic garden",
    in fixture: RunningChatFixture,
    persistenceName: String
) async throws -> HerdrHudChats.Chat {
    var accumulator = HerdrHudChatMetadataAccumulator()
    accumulator.reconcile(
        machineID: "synthetic",
        rootRunID: "root-run",
        expectedTurnCount: 1,
        samples: [.init(id: "run-1", costUSD: costUSD, modelName: modelName)]
    )
    let thread = HerdrHudSession.HerdrHudThread(
        machineID: "synthetic",
        rootRunID: "root-run",
        lastRunID: "run-1",
        turnCount: 1
    )
    let exchange = HerdrHudExchange(
        id: "run-1",
        machineID: "synthetic",
        prompt: title,
        sentPrompt: title,
        response: exchangeStatus == .failed ? nil : "The synthetic plan is ready.",
        error: exchangeStatus == .failed ? "Synthetic failure" : nil,
        status: exchangeStatus,
        costUSD: costUSD,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        promotedPaneID: nil,
        attachmentFilenames: [],
        modelLabel: modelName ?? "default"
    )
    try HerdrHudPersistenceSnapshot(
        thread: thread,
        exchanges: [exchange],
        hasUnseenAnswer: hasUnseenAnswer,
        chatMetadata: accumulator
    ).save(to: fixture.directory.appendingPathComponent("\(persistenceName).json"))
    let session = HerdrHudSession(
        userDefaults: fixture.defaults,
        persistenceURL: fixture.directory.appendingPathComponent("\(persistenceName).json")
    )
    await session.waitForPersistenceRestoreForTesting()
    return HerdrHudChats.Chat(id: persistenceName, title: title, session: session)
}

/// The smallest synthetic companion that accepts one HUD chat run and keeps
/// reporting it as running until the test stops it.
private final class RunningChatURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var runID = "agr_runningrender"
        var status = "running"
        var costUSD: Double = 0.37
        var model = "synthetic/sonnet-4-5"
    }

    static let state = Mutex(State())
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let payload = Self.state.withLock { state -> (Int, Data) in
            var response: [String: Any] = ["ok": true]
            let path = url.path
            if path.hasSuffix("/capabilities") {
                response["profiles"] = ["hud-chat-v1"]
                response["hudChatWorkingDirectory"] = true
            } else if path.hasSuffix("/cancel") {
                state.status = "cancelled"
                response["run"] = Self.run(state)
            } else if path == "/api/v1/agent-runs", request.httpMethod == "POST" {
                response["run"] = Self.run(state)
            } else if path.contains("/agent-runs/") {
                response["run"] = Self.run(state)
            }
            return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
        }
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: payload.0,
            httpVersion: nil,
            headerFields: nil
        ) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func run(_ state: State) -> [String: Any] {
        [
            "id": state.runID,
            "status": state.status,
            "prompt": "Plan the synthetic garden",
            "createdAt": "2026-09-01T12:00:00Z",
            "threadRootRunId": state.runID,
            "sessionFile": "synthetic.jsonl",
            "costUSD": state.costUSD,
            "model": state.model,
        ]
    }
}
