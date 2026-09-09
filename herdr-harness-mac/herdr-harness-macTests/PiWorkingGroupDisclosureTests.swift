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

    private func group(status: PiToolInvocation.Status) -> PiWorkingGroup {
        let tool = PiToolInvocation(
            id: "sample-tool", callID: "sample-call", name: "bash",
            arguments: nil, result: nil, status: status, startedAt: nil, finishedAt: nil
        )
        return PiWorkingGroup(
            id: "sample-group", items: [.tool(tool)], toolCount: 1, thinkingCount: 0,
            latestToolTitle: "Command", isLive: status == .running,
            failureCount: status == .failed ? 1 : 0
        )
    }
}
