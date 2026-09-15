import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("Clanking disclosure")
@MainActor
struct PiWorkingGroupDisclosureTests {
    @Test("Tool failure never expands a collapsed group, on mount or after an update")
    func failuresStayCollapsed() async throws {
        let running = group(status: .running)
        let failed = group(status: .failed)
        let controller = UIHostingController(
            rootView: PiWorkingGroupView(group: running).frame(width: 390)
        )
        controller.safeAreaRegions = []
        _ = controller.view
        try await Task.sleep(for: .milliseconds(100))
        let collapsedHeight = controller.sizeThatFits(in: CGSize(width: 390, height: 1_000)).height

        controller.rootView = PiWorkingGroupView(group: failed).frame(width: 390)
        try await Task.sleep(for: .milliseconds(300))
        let updatedHeight = controller.sizeThatFits(in: CGSize(width: 390, height: 1_000)).height
        #expect(updatedHeight == collapsedHeight)
        #expect(updatedHeight < 60)

        let initiallyFailed = UIHostingController(
            rootView: PiWorkingGroupView(group: failed).frame(width: 390)
        )
        initiallyFailed.safeAreaRegions = []
        _ = initiallyFailed.view
        try await Task.sleep(for: .milliseconds(100))
        let initiallyFailedHeight = initiallyFailed.sizeThatFits(
            in: CGSize(width: 390, height: 1_000)
        ).height
        #expect(initiallyFailedHeight == collapsedHeight)
    }

    @Test("A live failure update preserves an explicitly expanded group")
    func failurePreservesExpandedState() async throws {
        let controller = UIHostingController(
            rootView: PiWorkingGroupView(
                group: group(status: .running),
                initiallyExpanded: true
            ).frame(width: 390)
        )
        controller.safeAreaRegions = []
        _ = controller.view
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.sizeThatFits(in: CGSize(width: 390, height: 1_000)).height > 60)

        controller.rootView = PiWorkingGroupView(
            group: group(status: .failed),
            initiallyExpanded: false
        ).frame(width: 390)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.sizeThatFits(in: CGSize(width: 390, height: 1_000)).height > 60)
    }

    @Test("Only the dedicated failure count uses alert styling")
    func failureStylingAndSummary() {
        let failed = group(
            status: .failed,
            latestToolTitle: "A deliberately long synthetic command title that may truncate visually"
        )
        let view = PiWorkingGroupView(group: failed)

        #expect(view.chevronColor == HerdrTheme.mist)
        #expect(view.iconColor == HerdrTheme.muted)
        #expect(view.titleColor == HerdrTheme.mist)
        #expect(view.summaryColor == HerdrTheme.muted)
        #expect(view.failureCountColor == HerdrTheme.alert)
        #expect(view.stepSummary == "1 step")
        #expect(view.failureSummary == "1 failed")
        #expect(view.summary == "1 step · A deliberately long synthetic command title that may truncate visually · 1 failed")
    }

    private func group(
        status: PiToolInvocation.Status,
        latestToolTitle: String = "Command"
    ) -> PiWorkingGroup {
        let tool = PiToolInvocation(
            id: "sample-tool",
            callID: "sample-call",
            name: "bash",
            arguments: nil,
            result: nil,
            status: status,
            startedAt: nil,
            finishedAt: nil
        )
        return PiWorkingGroup(
            id: "sample-group",
            items: [.tool(tool)],
            toolCount: 1,
            thinkingCount: 0,
            latestToolTitle: latestToolTitle,
            isLive: status == .running,
            failureCount: status == .failed ? 1 : 0
        )
    }
}
