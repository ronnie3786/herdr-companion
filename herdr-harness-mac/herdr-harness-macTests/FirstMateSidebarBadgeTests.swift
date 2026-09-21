import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The Mac Chat navigator's First Mate attention badge.
///
/// The badge is global: it counts features on every configured host that wait
/// on a human decision (`awaiting_direction` or `blocked`), regardless of the
/// selected chat, host, or filters. These tests cover the presentation policy,
/// the observable wiring that feeds the badge from live fleet polling, and the
/// narrow-layout bound.
@Suite("First Mate sidebar badge", .serialized)
@MainActor
struct FirstMateSidebarBadgeTests {
    @Test("Zero hides the badge and only the visible number caps at 99+")
    func badgeVisibilityAndCap() {
        #expect(FirstMateNavigationButton.badgeText(for: 0) == nil)
        #expect(FirstMateNavigationButton.badgeText(for: -2) == nil)
        #expect(FirstMateNavigationButton.badgeText(for: 1) == "1")
        #expect(FirstMateNavigationButton.badgeText(for: 99) == "99")
        #expect(FirstMateNavigationButton.badgeText(for: 100) == "99+")
        #expect(FirstMateNavigationButton.badgeText(for: 4_312) == "99+")
    }

    @Test("Accessibility and help text keep the exact count and its meaning")
    func accessibilityCopy() {
        #expect(FirstMateNavigationButton.accessibilityValue(for: 0) == "No features waiting on your direction")
        #expect(FirstMateNavigationButton.accessibilityValue(for: 1) == "1 feature waiting on your direction")
        #expect(FirstMateNavigationButton.accessibilityValue(for: 3) == "3 features waiting on your direction")
        #expect(FirstMateNavigationButton.accessibilityValue(for: 150) == "150 features waiting on your direction")

        #expect(FirstMateNavigationButton.helpText(for: 0).contains("No features"))
        #expect(FirstMateNavigationButton.helpText(for: 1).contains("1 feature is waiting"))
        #expect(FirstMateNavigationButton.helpText(for: 150).contains("150 features are waiting"))
        #expect(FirstMateNavigationButton.helpText(for: 150).contains("latest status"))
    }

    @Test("The demo adapter counts human-decision statuses once per feature")
    func demoAdapterCountsWaitingFeatures() {
        let waiting = feature(id: "demo-waiting", status: "awaiting_direction")
        let blocked = feature(id: "demo-blocked", status: "blocked")
        let working = feature(id: "demo-working", status: "running")

        #expect(FirstMateAttention.count(features: [waiting, blocked, working, waiting], machineID: "demo") == 2)
        #expect(FirstMateAttention.count(features: [working], machineID: "demo") == 0)
        #expect(FirstMateAttention.count(features: [], machineID: "demo") == 0)
    }

    @Test("A hosted row gains and clears the badge as fleet polling reports attention")
    func hostedRowFollowsFleetPolling() async throws {
        let index = FirstMateFleetIndex()
        index.pollingInterval = .milliseconds(10)
        let gate = FirstMateBadgeStepGate()
        let machine = HerdrMachine(id: "alpha", name: "Alpha Mac", urlString: "https://alpha.example.invalid")
        let configuration = try #require(ServerConfiguration(urlString: machine.urlString, token: "synthetic-token"))
        let source = FirstMateFleetSource(
            machine: machine,
            configuration: configuration,
            client: FirstMateBadgeFleetClient(gate: gate)
        )

        var measuredSize = CGSize.zero
        let host = NSHostingView(rootView:
            FirstMateBadgeHost(index: index)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        let withoutBadge = measuredSize
        #expect(withoutBadge.width > 0, "The hosted row should lay out before polling starts")

        let observation = Task { await index.observe(sources: [source], connectionGeneration: 1) }
        defer {
            observation.cancel()
            Task { await gate.cancelPending() }
        }
        try await gate.waitForFetch()

        await gate.supply(.init(ok: true, features: [
            feature(id: "waiting", status: "awaiting_direction"),
            feature(id: "working", status: "running"),
        ]))
        try await waitForBadgeCondition("attention appears") {
            host.layoutSubtreeIfNeeded()
            return index.attentionCount == 1 && measuredSize.width > withoutBadge.width
        }
        let withBadge = measuredSize

        await gate.supply(.init(ok: true, features: [feature(id: "working", status: "running")]))
        try await waitForBadgeCondition("attention clears") {
            host.layoutSubtreeIfNeeded()
            return index.attentionCount == 0 && abs(measuredSize.width - withoutBadge.width) < 1
        }

        observation.cancel()
        await gate.cancelPending()
        await observation.value

        #expect(withBadge.width > withoutBadge.width, "Polling attention should widen the row with its badge")
    }

    @Test("The row fits the narrow navigator at regular and enlarged text", arguments: [HerdrFontScale.medium, .xxxLarge])
    func boundedNarrowLayout(scale: HerdrFontScale) async throws {
        var measured = CGSize.zero
        let host = NSHostingView(rootView:
            FirstMateNavigationButton(attentionCount: 123, action: {})
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
                .environment(\.herdrFontScale, scale)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        // The Chat navigator's declared minimum column is 240pt with 8pt of
        // horizontal padding on each side, so the row has 224pt to work with.
        #expect(measured.width > 0, "The row should lay out at \(scale.label)")
        #expect(measured.width <= 224, "The attention row needed \(measured.width)pt at \(scale.label)")
        #expect(measured.height > 0)
    }

    @Test("The sidebar places the badge on the First Mate entry only above zero")
    func sidebarPlacement() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let hidden = try await HerdrRenderHarness.render(
            "first-mate-sidebar-attention-hidden.png",
            size: CGSize(width: 280, height: 760)
        ) {
            HerdrSidebarView(
                model: model,
                openPane: { _ in },
                openWorkspace: { _ in },
                openFirstMate: {},
                firstMateAttentionCount: 0
            )
        }
        let shown = try await HerdrRenderHarness.render(
            "first-mate-sidebar-attention-shown.png",
            size: CGSize(width: 280, height: 760)
        ) {
            HerdrSidebarView(
                model: model,
                openPane: { _ in },
                openWorkspace: { _ in },
                openFirstMate: {},
                firstMateAttentionCount: 3
            )
        }
        hidden.expectSubstantial()
        shown.expectSubstantial()
        #expect(shown.byteCount != hidden.byteCount, "A positive attention count should change the rendered sidebar")
    }

    @Test("The navigator row renders hidden, counted, and capped badges")
    func rendersBadgeStates() async throws {
        var byteCounts: [Int: Int] = [:]
        for count in [0, 3, 123] {
            let result = try await HerdrRenderHarness.render(
                "first-mate-attention-\(count).png",
                size: CGSize(width: 300, height: 64)
            ) {
                FirstMateNavigationButton(attentionCount: count, action: {})
                    .padding(.horizontal, 8)
            }
            result.expectSubstantial(minimumBytes: 2_048)
            byteCounts[count] = result.byteCount
        }
        let hidden = try #require(byteCounts[0])
        let counted = try #require(byteCounts[3])
        let capped = try #require(byteCounts[123])
        #expect(counted != hidden, "A counted badge should change the render")
        #expect(capped != hidden, "A capped badge should change the render")
        #expect(capped != counted, "99+ should not render like 3")
    }

    private func feature(id: String, status: String) -> FirstMateFeature {
        var feature = FirstMateDemo.newFeature(
            title: "Synthetic feature \(id)",
            goal: "A synthetic goal for \(id)",
            cwd: "/tmp/synthetic",
            id: id
        ).feature
        feature.status = status
        return feature
    }
}

/// Reads the index inside a SwiftUI body so Observation registers the count the
/// navigator badge draws, exactly as `WorkspaceNavigationView` does.
private struct FirstMateBadgeHost: View {
    let index: FirstMateFleetIndex

    var body: some View {
        FirstMateNavigationButton(attentionCount: index.attentionCount, action: {})
    }
}

private enum FirstMateBadgeTestError: Error {
    case timedOut(String)
}

@MainActor
private func waitForBadgeCondition(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw FirstMateBadgeTestError.timedOut(description) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Holds each polling response until the test has observed the previous state,
/// so the badge transitions are deterministic rather than timing-dependent.
private actor FirstMateBadgeStepGate {
    private var queued: [FirstMateFeatureList] = []
    private var waiting: CheckedContinuation<FirstMateFeatureList, any Error>?
    private var fetches = 0

    var fetchCount: Int { fetches }

    func fetch() async throws -> FirstMateFeatureList {
        fetches += 1
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if queued.isEmpty {
                    waiting = continuation
                } else {
                    continuation.resume(returning: queued.removeFirst())
                }
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    func waitForFetch(_ count: Int = 1) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while fetches < count {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw FirstMateBadgeTestError.timedOut("fleet gate did not receive \(count) fetch(es)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func supply(_ response: FirstMateFeatureList) {
        if let waiting {
            waiting.resume(returning: response)
            self.waiting = nil
        } else {
            queued.append(response)
        }
    }

    func cancelPending() {
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
}

private final class FirstMateBadgeFleetClient: FirstMateClient, @unchecked Sendable {
    private let gate: FirstMateBadgeStepGate

    init(gate: FirstMateBadgeStepGate) {
        self.gate = gate
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { try await gate.fetch() }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
