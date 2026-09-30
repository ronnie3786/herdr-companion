import AppKit
import Darwin
import Observation
import os
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Opt-in local measurements of production code, using only synthetic data.
/// Set HERDR_FIRST_MATE_BENCHMARK=1 in the generated xctestrun environment.
/// Timings are evidence, not machine-dependent pass/fail thresholds.
@Suite("First Mate performance measurements", .serialized)
@MainActor
struct FirstMatePerformanceMeasurements {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HERDR_FIRST_MATE_BENCHMARK"] == "1" }

    static func snapshot() -> FirstMateSnapshot {
        var value = FirstMateDemo.chatWindowFeatures().first { $0.feature.id == "demo-receipts" }!
        // Keep the real composer mounted while the selected feature is idle.
        // Completed features intentionally replace it with a closed notice.
        value.feature.status = "paused"
        value.feature.verification = FirstMateVerification(status: .partiallyVerified, featureRevision: value.feature.revision,
            coverageReasons: ["Synthetic coverage is incomplete."], computedAt: "2030-01-01T00:00:00Z")
        value.runtimeHealth = FirstMateRuntimeHealth(status: "healthy", schedulerAlive: true,
            lastSuccessAt: "2030-01-01T00:00:00Z", errorKind: nil, consecutiveFailures: 0)
        value.messages = (0..<177).map { index in
            let role = index % 3 == 0 ? "user" : "assistant"
            let paragraph = "Synthetic response \(index). The sample workspace contains a small application and its tests. "
                + "We checked the implementation, reviewed the output, and recorded the next step.\n\n"
            return FirstMateMessage(id: "synthetic-message-\(index)", featureID: value.feature.id, role: role,
                text: role == "user" ? "Please check synthetic item \(index)." : String(repeating: paragraph, count: 16),
                status: "delivered", createdAt: "2030-01-01T10:00:00Z")
        }
        value.documents = (0..<173).map { index in
            FirstMateDocument(id: "synthetic-document-\(index)", featureID: value.feature.id,
                title: "Synthetic document \(index)", mediaType: "text/markdown", contentHash: "synthetic-\(index)",
                createdAt: "2030-01-01T10:00:00Z", content: "Synthetic document content.")
        }
        return value
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func report(_ label: String, _ measurements: [Double]) {
        let sorted = measurements.sorted()
        guard !sorted.isEmpty else { return }
        print("FM_PERF \(label): n=\(sorted.count) median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]) max_ms=\(sorted.last!)")
    }

    @Test func textAndPublication() throws {
        guard Self.enabled else { return }
        let snapshot = Self.snapshot()
        var measurements: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let cards = FirstMateTranscriptLayout.fileCards(messages: snapshot.messages, documents: snapshot.documents)
            #expect(cards.isEmpty)
            measurements.append(Self.milliseconds(start.duration(to: .now)))
        }
        Self.report("file-cards", measurements)
        let catalog = FirstMateMentionCatalog(entries: (0..<74).map {
            .init(name: "Synthetic agent \($0)", emoji: "✦", status: .idle, target: .feature(featureID: "synthetic-\($0)"))
        })
        let text = AttributedString(snapshot.messages[1].text)
        measurements = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for _ in 0..<20 { #expect(FirstMateMentionLinker.link(text, catalog: catalog) == text) }
            measurements.append(Self.milliseconds(start.duration(to: .now)))
        }
        Self.report("mentions-20-blocks", measurements)

        let store = FirstMateStore()
        store.receive(snapshot)
        let publications = OSAllocatedUnfairLock(initialState: 0)
        for index in 1...10 {
            withObservationTracking {
                _ = store.snapshots
            } onChange: {
                publications.withLock { $0 += 1 }
            }
            var poll = snapshot
            poll.feature.verification?.computedAt = "2030-01-01T00:00:\(String(format: "%02d", index))Z"
            poll.runtimeHealth?.lastSuccessAt = poll.feature.verification?.computedAt
            store.receive(poll)
        }
        print("FM_PERF unchanged-poll-publications: \(publications.withLock { $0 }) / 10")
    }

    @Test func conversationOpening() async throws {
        guard Self.enabled else { return }
        let client = SyntheticChatFleetClient(features: [ChatFixtures.feature("f1"), ChatFixtures.feature("f2")])
        client.beforeFeatureList = { try await Task.sleep(for: .milliseconds(600)) }
        client.beforeFeature = { _ in try await Task.sleep(for: .milliseconds(100)) }
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: false), shell: ChatFixtures.shell(),
            configuration: { ServerConfiguration(urlString: "https://\($0).example.invalid", token: "synthetic") },
            makeClient: { _ in client }, fleetSources: { [] })
        let start = ContinuousClock.now
        session.select(.feature(.init(machineID: "synthetic", featureID: "f1")))
        let task = Task { await session.run() }
        defer { task.cancel() }
        try await ChatFixtures.waitUntil("first conversation", timeout: .seconds(10)) { session.selectedSnapshot != nil }
        Self.report("cold-open-list600-snapshot100", [Self.milliseconds(start.duration(to: .now))])
        // Switch while the previous chat's next request is deliberately slow.
        client.beforeFeature = { id in try await Task.sleep(for: id == "f1" ? .milliseconds(800) : .milliseconds(100)) }
        let calls = client.featureCalls
        session.wakeRefresh()
        try await ChatFixtures.waitUntil("slow old request") { client.featureCalls > calls }
        let switchStart = ContinuousClock.now
        session.select(.feature(.init(machineID: "synthetic", featureID: "f2")))
        try await ChatFixtures.waitUntil("second conversation", timeout: .seconds(10)) { session.selectedSnapshot != nil }
        Self.report("switch-during-slow-old-request", [Self.milliseconds(switchStart.duration(to: .now))])
        print("FM_PERF opening-requests: lists=\(client.featureListCalls) snapshots=\(client.featureCalls) capabilities=\(client.capabilityCalls)")
        task.cancel()
        await task.value
    }

    @Test func localWindow() async throws {
        guard Self.enabled else { return }
        let session = FirstMateChatWindowSession(model: ChatFixtures.model(demo: true), shell: ChatFixtures.shell())
        let store = try #require(session.store(for: "demo"))
        var poll = Self.snapshot()
        store.receive(poll)
        session.select(.feature(.init(machineID: "demo", featureID: poll.feature.id)))
        session.inspectorPreference = false
        let root = FirstMateChatWindowRoot(session: session, modelFavorites: ModelFavoritesStore())
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic First Mate performance measurement"
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(25)) }

        for phase in ["idle", "draft-edits", "scroll", "native-input", "reply-arrival"] {
            let start = ContinuousClock.now
            let cpuStart = Self.cpuSeconds()
            let initialDraftLength = store.draft.count
            let editor: NSTextView?
            if phase == "native-input" {
                let editable = Self.textViews(hosting).first { $0.isEditable }
                editor = try #require(editable)
            } else {
                editor = nil
            }
            if let editor { window.makeFirstResponder(editor) }
            var delays: [Double] = []
            for index in 0..<200 {
                let inputStart = ContinuousClock.now
                if index % 100 == 0 {
                    poll.feature.verification?.computedAt = "2030-01-01T00:\(phase == "idle" ? "01" : phase == "draft-edits" ? "02" : "03"):\(index == 0 ? "00" : "02")Z"
                    poll.runtimeHealth?.lastSuccessAt = poll.feature.verification?.computedAt
                    if phase == "reply-arrival" {
                        poll.messages.append(.init(id: "arriving-reply-\(index)", featureID: poll.feature.id,
                            role: "assistant", text: "Read Synthetic document \(index). A new synthetic reply has arrived.",
                            status: "delivered", createdAt: "2030-01-01T10:01:00Z"))
                    }
                    store.receive(poll)
                }
                if phase == "draft-edits" { store.draft.append(index % 20 == 0 ? "\n" : "a") }
                editor?.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
                if phase == "scroll", let scroll = Self.scrollViews(hosting).max(by: { $0.frame.width < $1.frame.width }) {
                    let clip = scroll.contentView
                    let height = scroll.documentView?.frame.height ?? 0
                    let limit = max(0, height - clip.bounds.height)
                    clip.scroll(to: NSPoint(x: 0, y: min(limit, max(0, clip.bounds.origin.y + (index < 100 ? -28 : 28)))))
                    scroll.reflectScrolledClipView(clip)
                }
                let before = phase == "native-input" ? inputStart : ContinuousClock.now
                try await Task.sleep(for: .milliseconds(20))
                delays.append(max(0, Self.milliseconds(before.duration(to: .now)) - 20))
            }
            Self.report("window-\(phase)-main-actor-delay", delays)
            let seconds = Self.milliseconds(start.duration(to: .now)) / 1000
            print("FM_PERF window-\(phase)-cpu-percent: \((Self.cpuSeconds() - cpuStart) / seconds * 100)")
            if editor != nil { #expect(store.draft.count == initialDraftLength + 200, "Native text input reaches the draft without lost characters") }
        }
    }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
