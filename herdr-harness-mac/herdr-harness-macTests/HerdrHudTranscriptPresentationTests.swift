import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("HUD Clanking presentation")
@MainActor
struct HerdrHudTranscriptPresentationTests {
    @Test("Grouping hides partial assistant prose but always reveals terminal responses")
    func groupedResponseVisibility() {
        #expect(!HerdrHudTranscriptPresentation.showsResponse(
            status: .running,
            groupAllClankingActivity: true
        ))
        #expect(HerdrHudTranscriptPresentation.showsResponse(
            status: .running,
            groupAllClankingActivity: false
        ))
        for status in [HeadlessAgentRunStatus.completed, .failed, .cancelled, .promoted] {
            #expect(HerdrHudTranscriptPresentation.showsResponse(
                status: status,
                groupAllClankingActivity: true
            ))
        }
    }

    @Test("A failed HUD tool never opens the collapsed Clanking disclosure")
    func failuresStayCollapsed() async throws {
        let running = exchange(stepIsFailure: false)
        let failed = exchange(stepIsFailure: true)
        let hosting = NSHostingView(rootView: HerdrHudWorkingGroupView(exchange: running).frame(width: 420))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let collapsedHeight = hosting.fittingSize.height

        hosting.rootView = HerdrHudWorkingGroupView(exchange: failed).frame(width: 420)
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height == collapsedHeight)
        #expect(hosting.fittingSize.height < 55)

        let initiallyFailed = NSHostingView(rootView: HerdrHudWorkingGroupView(exchange: failed).frame(width: 420))
        window.contentView = initiallyFailed
        try await Task.sleep(for: .milliseconds(300))
        initiallyFailed.layoutSubtreeIfNeeded()
        #expect(initiallyFailed.fittingSize.height == collapsedHeight)
    }

    private func exchange(stepIsFailure: Bool) -> HerdrHudExchange {
        HerdrHudExchange(
            id: "synthetic-exchange",
            machineID: "synthetic-machine",
            prompt: "Synthetic prompt",
            sentPrompt: "Synthetic prompt",
            response: "Synthetic response",
            error: nil,
            status: stepIsFailure ? .failed : .completed,
            costUSD: nil,
            createdAt: .now,
            promotedPaneID: nil,
            attachmentFilenames: [],
            steps: [
                HerdrHudStep(
                    id: "synthetic-step",
                    title: "Command",
                    detail: "Synthetic detail",
                    symbol: "terminal",
                    isFailure: stepIsFailure,
                    isRunning: false
                )
            ]
        )
    }
}
