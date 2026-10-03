import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate archive cleanup render", .serialized)
@MainActor
struct FirstMateArchiveRenderTests {
    @Test("Archive review shows retained evidence, resource choices and space estimates", arguments: [ColorScheme.dark])
    func review(scheme: ColorScheme) async throws {
        let store = FirstMateStore()
        let model = FirstMateArchiveModel(feature: FirstMateArchiveReviewTests.feature,
            readPreview: { FirstMateArchiveReviewTests.preview },
            archive: { _ in throw APIError.invalidResponse },
            readProgress: { _, _ in throw APIError.invalidResponse })
        await model.load()
        let render = try await HerdrRenderHarness.render("first-mate-archive-review-\(scheme == .dark ? "dark" : "light").png",
            size: CGSize(width: 780, height: 900)) {
                FirstMateArchiveReviewSheet(store: store, model: model).environment(\.colorScheme, scheme)
            }
        render.expectSubstantial(minimumBytes: 3_000)
    }

    @Test("Blocking cleanup renders real progress and logs", arguments: [ColorScheme.dark])
    func progress(scheme: ColorScheme) async throws {
        var cleanup = FirstMateArchiveReviewTests.cleanup
        cleanup.status = "running"
        cleanup.message = "Removing selected temporary build resources."
        let render = try await HerdrRenderHarness.render("first-mate-archive-progress-\(scheme == .dark ? "dark" : "light").png",
            size: CGSize(width: 720, height: 520)) {
                FirstMateArchiveProgressView(cleanup: cleanup, logs: [FirstMateArchiveReviewTests.log(sequence: 1)], isWorking: true)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(FirstMatePalette(scheme: scheme).background).environment(\.colorScheme, scheme)
            }
        render.expectSubstantial(minimumBytes: 3_000)
    }

    @Test("Saved history and cleanup results render in dark appearance", arguments: [ColorScheme.dark])
    func renders(scheme: ColorScheme) async throws {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var feature = FirstMateDemo.features(step: 0)[0].feature
        feature.status = "completed"
        feature.archivedAt = FirstMateDemo.timestamp
        feature.archiveCleanup = .init(id: "archive_synthetic", status: "completed", attempt: 1,
            message: "Cleanup finished. History and retained resources remain available.", historyAvailable: true,
            bytesReclaimed: 120_000_000, removed: 2, retained: 5, failed: 0, updatedAt: FirstMateDemo.timestamp)
        let render = try await HerdrRenderHarness.render("first-mate-archive-\(scheme == .dark ? "dark" : "light").png",
            size: CGSize(width: 540, height: 430)) {
            FirstMateArchiveSection(store: store, feature: feature)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(FirstMatePalette(scheme: scheme).background)
                .environment(\.colorScheme, scheme)
        }
        render.expectSubstantial(minimumBytes: 2_048)
    }
}
