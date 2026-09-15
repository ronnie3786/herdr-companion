import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Clanking disclosure")
@MainActor
struct PiWorkingGroupDisclosureTests {
    @Test("Tool failure never expands a collapsed group, on mount or after an update")
    func failuresStayCollapsed() async throws {
        let running = group(status: .running)
        let failed = group(status: .failed)
        let hosting = NSHostingView(rootView: PiWorkingGroupView(group: running).frame(width: 420))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let collapsedHeight = hosting.fittingSize.height
        hosting.rootView = PiWorkingGroupView(group: failed).frame(width: 420)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height == collapsedHeight)
        #expect(hosting.fittingSize.height < 50)
        #expect(failed.hasFailure)
        #expect(failed.failureCount == 1)
        let initiallyFailed = NSHostingView(rootView: PiWorkingGroupView(group: failed).frame(width: 420))
        window.contentView = initiallyFailed
        try await Task.sleep(for: .milliseconds(300))
        initiallyFailed.layoutSubtreeIfNeeded()
        #expect(initiallyFailed.fittingSize.height == collapsedHeight)
    }

    @Test("A live failure update preserves an explicitly expanded group")
    func failurePreservesExpandedState() async throws {
        let running = group(status: .running)
        let failed = group(status: .failed)
        let hosting = NSHostingView(
            rootView: PiWorkingGroupView(group: running, initiallyExpanded: true).frame(width: 420)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let expandedHeight = hosting.fittingSize.height
        #expect(expandedHeight > 50)

        hosting.rootView = PiWorkingGroupView(
            group: failed,
            initiallyExpanded: false
        ).frame(width: 420)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 50)
    }

    @Test("Only the dedicated failure count uses alert styling")
    func failureStylingAndSummary() {
        let failed = group(
            status: .failed,
            latestToolTitle: "A deliberately long synthetic command title that may truncate visually"
        )
        let view = PiWorkingGroupView(group: failed)

        #expect(view.chevronColor == HerdrTheme.mist)
        #expect(view.borderColor == HerdrTheme.subtleSeparator)
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
            id: "sample-tool", callID: "sample-call", name: "bash",
            arguments: nil, result: nil, status: status, startedAt: nil, finishedAt: nil
        )
        return PiWorkingGroup(
            id: "sample-group", items: [.tool(tool)], toolCount: 1, thinkingCount: 0,
            latestToolTitle: latestToolTitle, isLive: status == .running,
            failureCount: status == .failed ? 1 : 0
        )
    }
}
