import SwiftUI

/// Synthetic resources for an explicitly requested debug demo. No filesystem operations.
#if DEBUG
@MainActor
final class FirstMateArchiveDemo {
    private var tick = 0
    private var selected: [FirstMateArchiveResource] = []
    private let archiveID = "archive_demo"
    private static let timestamp = "2026-10-03T15:42:08Z"

    private static var resources: [FirstMateArchiveResource] {
        [
            .init(id: "build", kind: "temporary_build", path: "/workspace/atlas/build/search-preview", estimatedBytes: 780_000_000,
                  canDelete: true, reason: "Temporary output owned by this session.", selectedByDefault: true),
            .init(id: "cache", kind: "cache", path: "/workspace/atlas/cache/search-index", estimatedBytes: 260_000_000,
                  canDelete: true, reason: "Disposable cache. Recreated on the next build.", selectedByDefault: true),
            .init(id: "worktree", kind: "worktree", path: "/workspace/atlas/worktrees/search-results", estimatedBytes: 12_000_000,
                  canDelete: false, reason: "Uncommitted changes found. This worktree will be kept.", selectedByDefault: false),
        ]
    }

    static func makeModel(feature: FirstMateFeature, onArchived: @escaping () async -> Void) -> FirstMateArchiveModel {
        let demo = FirstMateArchiveDemo()
        let sample = feature
        return FirstMateArchiveModel(feature: sample, readPreview: {
            .init(featureID: sample.id, featureRevision: sample.revision, token: "demo-preview",
                  resources: resources, documentCount: 4, messageCount: 38)
        }, archive: { request in
            await onArchived()
            demo.selected = resources.filter { request.cleanupOptions.resourceIDs.contains($0.id) && $0.canDelete }
            return .init(ok: true, feature: sample, archiveID: demo.archiveID, cleanup: demo.summary(finished: false))
        }, readProgress: { _, after in
            demo.tick += 1
            let finished = demo.tick >= 14
            let entries = demo.logs(finished: finished).filter { $0.sequence > after }
            return .init(ok: true, cleanup: demo.summary(finished: finished), logs: entries, nextAfter: nil)
        })
    }

    private func summary(finished: Bool) -> FirstMateArchiveCleanup {
        .init(id: archiveID, status: finished ? "completed" : "running", attempt: 1,
              message: finished ? "Selected resources cleaned up. Your saved record is ready." : "Checking ownership and removing the selected files on the companion.",
              historyAvailable: true, bytesReclaimed: selected.prefix(finished ? selected.count : 1).reduce(0) { $0 + ($1.estimatedBytes ?? 0) },
              removed: finished ? selected.count : min(1, selected.count), retained: 1, failed: 0, updatedAt: Self.timestamp)
    }

    private func logs(finished: Bool) -> [FirstMateCleanupLogEntry] {
        var entries: [FirstMateCleanupLogEntry] = [
            .init(sequence: 1, kind: "history", path: "Search completed work / DEMO-204", outcome: "cataloged",
                  reason: "Documents, conversation and outcome saved to the catalog.", bytesReclaimed: 0, createdAt: Self.timestamp),
            .init(sequence: 2, kind: "worktree", path: Self.resources[2].path, outcome: "retained",
                  reason: "Uncommitted changes found. Your work is protected.", bytesReclaimed: 0, createdAt: Self.timestamp),
        ]
        for (index, resource) in selected.prefix(finished ? selected.count : 1).enumerated() {
            entries.append(.init(sequence: index + 3, kind: resource.kind, path: resource.path, outcome: "removed",
                                 reason: "Ownership checked and saved history verified.", bytesReclaimed: resource.estimatedBytes ?? 0, createdAt: Self.timestamp))
        }
        return entries
    }
}
#endif
