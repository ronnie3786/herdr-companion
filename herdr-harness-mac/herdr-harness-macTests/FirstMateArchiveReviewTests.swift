import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate archive review")
@MainActor
struct FirstMateArchiveReviewTests {
    @Test("Completed sessions require review when the server has cleanup capability")
    func capabilityCompatibility() {
        #expect(FirstMateArchiveSheet.flow(status: "completed", supportsCleanup: true, supportsReview: true) == .review)
        #expect(FirstMateArchiveSheet.flow(status: "completed", supportsCleanup: true, supportsReview: false) == .updateRequired)
        #expect(FirstMateArchiveSheet.flow(status: "completed", supportsCleanup: false, supportsReview: false) == .visibilityOnly)
        #expect(FirstMateArchiveSheet.flow(status: "running", supportsCleanup: true, supportsReview: true) == .visibilityOnly)
    }

    @Test("Mac First Mate remains dark even with a legacy light preference")
    func darkAppearance() {
        let store = FirstMateStore()
        store.isDark = false
        #expect(store.colorScheme == .dark)
    }

    @Test("Confirmation uses exactly the reviewed selection and follows the same archive through paged logs")
    func reviewedSelection() async throws {
        var requests: [FirstMateArchiveRequest] = []
        var cursors: [Int] = []
        var identities: [String?] = []
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { Self.preview },
            archive: { request in requests.append(request); return Self.snapshot },
            readProgress: { id, cursor in
                identities.append(id)
                cursors.append(cursor)
                return .init(ok: true, cleanup: Self.cleanup, logs: [Self.log(sequence: cursor + 1)], nextAfter: cursor == 0 ? 1 : nil)
            })
        await model.load()
        #expect(model.canConfirm)
        #expect(model.selectedCount == 2)
        #expect(model.estimatedBytes == 4_096)
        #expect(model.hasUnknownSize)
        #expect(model.choices.last?.delete == false)
        model.choices[0].delete = false
        model.keepDocuments = false
        await model.submit()
        let request = try #require(requests.first)
        #expect(request.cleanupOptions.resourceIDs == ["cache_unknown"])
        #expect(!request.cleanupOptions.keepDocuments)
        #expect(request.cleanupOptions.keepChat)
        #expect(request.expectedRevision == 5)
        #expect(request.previewToken == "synthetic-preview")
        #expect(model.phase == .finished)
        #expect(!model.isBlocking)
        #expect(cursors == [0, 1])
        #expect(identities == ["archive_synthetic", "archive_synthetic"])
        #expect(model.logs.map(\.sequence) == [1, 2])
    }

    @Test("A lost response retries the same idempotent request and frozen retention choices")
    func ambiguousArchive() async throws {
        var requests: [FirstMateArchiveRequest] = []
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { Self.preview },
            archive: { request in
                requests.append(request)
                if requests.count == 1 { throw URLError(.networkConnectionLost) }
                return Self.snapshot
            }, readProgress: { _, _ in .init(ok: true, cleanup: Self.cleanup, logs: [], nextAfter: nil) })
        await model.load()
        await model.submit()
        #expect(model.phase == .interrupted)
        #expect(!model.canConfirm)
        model.keepChat = false
        model.choices = []
        await model.resume()
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(model.phase == .finished)
    }

    @Test("A stale preview requires a fresh review before submission")
    func stalePreview() async throws {
        var reads = 0
        var requests = 0
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { reads += 1; return Self.preview },
            archive: { _ in requests += 1; throw APIError.server(status: 409, message: "archive_preview_stale") },
            readProgress: { _, _ in throw APIError.invalidResponse })
        await model.load()
        await model.submit()
        #expect(!model.canConfirm)
        #expect(model.preview == nil)
        await model.submit()
        #expect(requests == 1)
        await model.load()
        #expect(reads == 2)
        #expect(model.canConfirm)
    }

    @Test("Progress cannot switch to another archive generation")
    func pinsArchiveGeneration() async throws {
        var other = Self.cleanup
        other.id = "archive_other"
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { Self.preview }, archive: { _ in Self.snapshot },
            readProgress: { _, _ in .init(ok: true, cleanup: other, logs: [Self.log(sequence: 1)], nextAfter: nil) })
        await model.load()
        await model.submit()
        #expect(model.phase == .interrupted)
        #expect(model.logs.isEmpty)
        #expect(model.archiveID == "archive_synthetic")
    }

    @Test("Ineligible sessions cannot submit cleanup")
    func eligibility() async throws {
        var preview = Self.preview
        preview.eligible = false
        preview.ineligibleReason = "Work is still running."
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { preview }, archive: { _ in Issue.record("Unexpected archive"); return Self.snapshot },
            readProgress: { _, _ in throw APIError.invalidResponse })
        await model.load()
        #expect(!model.canConfirm)
        await model.submit()
        #expect(model.phase == .review)
    }

    @Test("Read-only preview failures cannot leave an earlier plan actionable")
    func failedReload() async throws {
        var reads = 0
        let model = FirstMateArchiveModel(feature: Self.feature,
            readPreview: { reads += 1; if reads > 1 { throw URLError(.notConnectedToInternet) }; return Self.preview },
            archive: { _ in Self.snapshot }, readProgress: { _, _ in throw APIError.invalidResponse })
        await model.load()
        await model.load()
        #expect(!model.canConfirm)
    }

    static var feature: FirstMateFeature {
        var feature = FirstMateDemo.features(step: 0)[0].feature
        feature.status = "completed"
        feature.revision = 5
        return feature
    }

    static var preview: FirstMateArchivePreview {
        .init(featureID: feature.id, featureRevision: 5, token: "synthetic-preview", resources: [
            .init(id: "build", kind: "temporary_build", path: "/workspace/managed/build", estimatedBytes: 4_096,
                  canDelete: true, reason: "Owned disposable build directory.", selectedByDefault: true),
            .init(id: "cache_unknown", kind: "cache", path: "/workspace/managed/cache", estimatedBytes: nil,
                  canDelete: true, reason: "Size measurement is incomplete.", selectedByDefault: true),
            .init(id: "dirty", kind: "worktree", path: "/workspace/managed/changes", estimatedBytes: 2_048,
                  canDelete: false, reason: "Uncommitted changes are retained.", selectedByDefault: true),
        ], documentCount: 2, messageCount: 30)
    }

    static var cleanup: FirstMateArchiveCleanup {
        .init(id: "archive_synthetic", status: "completed", attempt: 1, message: "Selected resources cleaned up.",
              historyAvailable: true, bytesReclaimed: 4_096, removed: 1, retained: 5, failed: 0, updatedAt: FirstMateDemo.timestamp)
    }

    static var snapshot: FirstMateArchiveReceipt {
        var value = feature
        value.archivedAt = FirstMateDemo.timestamp
        value.archiveCleanup = cleanup
        return .init(ok: true, feature: value, archiveID: cleanup.id, cleanup: cleanup)
    }

    static func log(sequence: Int) -> FirstMateCleanupLogEntry {
        .init(sequence: sequence, kind: "temporary_build", path: "/workspace/managed/build", outcome: "removed",
              reason: "Removed after verifying the catalog record.", bytesReclaimed: 4_096, createdAt: FirstMateDemo.timestamp)
    }
}
