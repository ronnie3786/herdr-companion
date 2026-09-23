import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Pi compaction renders", .serialized)
@MainActor
struct PiCompactionRenderTests {
    @Test("Completion and progress stay readable at a narrow width and large text")
    func narrowLargeTextStates() async throws {
        let progress = try await render(
            "pi-compaction-progress-narrow.png",
            presentation: PiCompactionStatusPresentation(
                kind: .progress,
                title: "Compacting context after overflow, then retrying…",
                detail: nil,
                systemImage: "arrow.triangle.2.circlepath"
            )
        )
        progress.expectSubstantial(minimumBytes: 2_048)

        let completion = try await render(
            "pi-compaction-complete-narrow.png",
            presentation: PiCompactionStatusPresentation.resolve(
                activity: nil,
                completion: PiCompactionCompletion(
                    evidence: .entry("compact-1"),
                    reason: .threshold,
                    sessionID: "s1",
                    timestamp: nil
                ),
                readiness: PiCompactionReadiness(
                    isConnected: true,
                    phase: .working,
                    availableDispositions: [.steer, .followUp]
                )
            )
        )
        completion.expectSubstantial(minimumBytes: 2_048)
    }

    @Test("Offline completion copy stays readable without claiming readiness")
    func offlineCompletion() async throws {
        let rendered = try await render(
            "pi-compaction-complete-offline.png",
            presentation: PiCompactionStatusPresentation.resolve(
                activity: nil,
                completion: PiCompactionCompletion(
                    evidence: .eventCursor("12"),
                    reason: .overflow,
                    sessionID: "s1",
                    timestamp: nil
                ),
                readiness: PiCompactionReadiness(
                    isConnected: false,
                    phase: .idle,
                    availableDispositions: []
                )
            )
        )
        rendered.expectSubstantial(minimumBytes: 2_048)
    }

    private func render(
        _ name: String,
        presentation: PiCompactionStatusPresentation?
    ) async throws -> HerdrRenderHarness.RenderResult {
        try await HerdrRenderHarness.render(name, size: CGSize(width: 320, height: 180)) {
            VStack(alignment: .leading, spacing: 10) {
                if let presentation {
                    PiCompactionStatusBar(presentation: presentation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.herdrFontScale, .xxLarge)
            .padding(12)
            .background(HerdrTheme.graphite)
        }
    }
}
