import SwiftUI

struct FirstMateArchiveSection: View {
    let store: FirstMateStore
    let feature: FirstMateFeature
    private let lifecycle: FirstMateStore.LifecycleIdentity

    init(store: FirstMateStore, feature: FirstMateFeature) {
        self.store = store
        self.feature = feature
        self.lifecycle = store.lifecycle
    }
    @State private var showReport = false
    @State private var retrying = false
    @State private var retryID = UUID().uuidString
    @State private var error: String?

    var body: some View {
        if let cleanup = feature.archiveCleanup {
            VStack(alignment: .leading, spacing: 10) {
                Label("Archive cleanup", systemImage: "archivebox")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(cleanup.status.capitalized).font(.subheadline.bold())
                if cleanup.isRunning { ProgressView().accessibilityLabel("Archive cleanup in progress") }
                Text(cleanup.message).font(.callout).textSelection(.enabled)
                Text("\(cleanup.removed) removed · \(cleanup.retained) retained · \(cleanup.failed) failed")
                    .font(.caption)
                Text("Approximately \(ByteCountFormatter.string(fromByteCount: cleanup.bytesReclaimed, countStyle: .file)) reclaimed")
                    .font(.caption)
                if cleanup.historyAvailable {
                    Text("Verification and usage are historical facts saved at archive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Completion record and cleanup log", systemImage: "doc.text") { showReport = true }
                if feature.isArchived && cleanup.canRetry {
                    Button("Retry cleanup", systemImage: "arrow.clockwise") {
                        Task { await retry() }
                    }
                    .disabled(retrying)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Unarchiving restores visibility. Removed temporary resources are not recreated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showReport) {
                FirstMateArchiveReportView(store: store, featureID: feature.id, archiveID: cleanup.id)
            }
            .accessibilityIdentifier("first-mate-archive-cleanup")
        }
    }

    private func retry() async {
        retrying = true
        defer { retrying = false }
        error = nil
        do {
            try await store.retryCleanup(featureID: feature.id, requestID: retryID, lifecycle: lifecycle)
            retryID = UUID().uuidString
        } catch is CancellationError {
            error = "The connection changed. Open this session again before retrying."
        } catch { self.error = error.localizedDescription }
    }
}
