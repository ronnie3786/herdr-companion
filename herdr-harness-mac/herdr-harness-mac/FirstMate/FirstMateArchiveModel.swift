import Foundation
import Observation

@MainActor @Observable
final class FirstMateArchiveModel {
    enum Phase { case loading, review, submitting, running, finished, interrupted }

    let feature: FirstMateFeature
    private(set) var phase = Phase.loading
    private(set) var preview: FirstMateArchivePreview?
    var choices: [FirstMateArchiveChoice] = []
    var keepDocuments = true
    var keepChat = true
    var reason: FirstMateArchiveReason?
    private(set) var cleanup: FirstMateArchiveCleanup?
    private(set) var logs: [FirstMateCleanupLogEntry] = []
    private(set) var error: String?
    private(set) var archiveID: String?
    @ObservationIgnored private var pendingRequest: FirstMateArchiveRequest?
    @ObservationIgnored private var after = 0
    @ObservationIgnored private let readPreview: () async throws -> FirstMateArchivePreview
    @ObservationIgnored private let archive: (FirstMateArchiveRequest) async throws -> FirstMateArchiveReceipt
    @ObservationIgnored private let readProgress: (String?, Int) async throws -> FirstMateArchiveProgress

    init(feature: FirstMateFeature,
         readPreview: @escaping () async throws -> FirstMateArchivePreview,
         archive: @escaping (FirstMateArchiveRequest) async throws -> FirstMateArchiveReceipt,
         readProgress: @escaping (String?, Int) async throws -> FirstMateArchiveProgress) {
        self.feature = feature
        self.readPreview = readPreview
        self.archive = archive
        self.readProgress = readProgress
    }

    convenience init(store: FirstMateStore, feature: FirstMateFeature,
                     isConnectionCurrent: @escaping () -> Bool = { true }) {
        let lifecycle = store.lifecycle
        self.init(feature: feature,
            readPreview: {
                guard isConnectionCurrent() else { throw CancellationError() }
                let value = try await store.archivePreview(featureID: feature.id, lifecycle: lifecycle)
                guard isConnectionCurrent() else { throw CancellationError() }
                return value
            }, archive: { request in
                guard isConnectionCurrent() else { throw CancellationError() }
                let value = try await store.confirmArchive(featureID: feature.id, request: request, lifecycle: lifecycle)
                guard isConnectionCurrent() else { throw CancellationError() }
                return value
            }, readProgress: { archiveID, after in
                guard isConnectionCurrent() else { throw CancellationError() }
                let value = try await store.archiveProgress(featureID: feature.id, archiveID: archiveID, after: after, lifecycle: lifecycle)
                guard isConnectionCurrent() else { throw CancellationError() }
                return value
            })
    }

    var isBlocking: Bool { phase == .submitting || phase == .running }
    var canConfirm: Bool { phase == .review && preview?.eligible == true && pendingRequest == nil && error == nil }
    var selectedCount: Int { choices.filter { $0.delete && $0.resource.canDelete }.count }
    var estimatedBytes: Int64 { choices.filter { $0.delete && $0.resource.canDelete }.reduce(0) { $0 + ($1.resource.estimatedBytes ?? 0) } }
    var hasUnknownSize: Bool { choices.contains { $0.delete && $0.resource.estimatedBytes == nil } }
    var compactsCopies: Bool { !keepDocuments || !keepChat }
    var confirmTitle: String { selectedCount > 0 ? "Archive and delete selected" : (compactsCopies ? "Archive and move copies" : "Archive and keep resources") }

    func load() async {
        guard pendingRequest == nil, archiveID == nil else { return }
        phase = .loading
        error = nil
        preview = nil
        choices = []
        do {
            let value = try await readPreview()
            try Task.checkCancellation()
            guard value.featureID == feature.id else { throw APIError.invalidResponse }
            preview = value
            choices = value.resources.map { .init(resource: $0, delete: $0.canDelete && $0.selectedByDefault) }
            phase = .review
        } catch {
            self.error = error.localizedDescription
            phase = .review
        }
    }

    func submit() async {
        guard !isBlocking, let preview else { return }
        if pendingRequest == nil {
            guard canConfirm else { return }
            pendingRequest = .init(requestID: UUID().uuidString, reason: reason?.rawValue,
                expectedRevision: preview.featureRevision, previewToken: preview.token,
                cleanupOptions: .init(resourceIDs: choices.filter { $0.delete && $0.resource.canDelete }.map(\.id).sorted(),
                                      keepDocuments: keepDocuments, keepChat: keepChat))
        }
        guard let pendingRequest else { return }
        phase = .submitting
        error = nil
        do {
            let response = try await archive(pendingRequest)
            guard response.ok, response.feature.id == feature.id,
                  response.archiveID == response.cleanup.id else { throw APIError.invalidResponse }
            self.cleanup = response.cleanup
            archiveID = response.archiveID
            await poll()
        } catch {
            if case APIError.server(let status, _) = error, status == 409 {
                self.pendingRequest = nil
                self.preview = nil
                phase = .review
                self.error = "The session or its resources changed. Reload the preview and review your choices again. \(error.localizedDescription)"
            } else {
                phase = .interrupted
                self.error = "The archive result could not be confirmed. Resume to check the same request safely. \(error.localizedDescription)"
            }
        }
    }

    func resume() async {
        if archiveID == nil { await submit() } else { await poll() }
    }

    private func poll() async {
        phase = .running
        error = nil
        do {
            while true {
                try Task.checkCancellation()
                let value = try await readProgress(archiveID, after)
                guard value.ok, let current = value.cleanup, current.id == archiveID else { throw APIError.invalidResponse }
                cleanup = current
                let newLogs = value.logs.filter { $0.sequence > after }.sorted { $0.sequence < $1.sequence }
                logs.append(contentsOf: newLogs)
                if logs.count > 1_000 { logs.removeFirst(logs.count - 1_000) }
                if let last = newLogs.last { after = last.sequence }
                if let next = value.nextAfter {
                    guard next == after, !newLogs.isEmpty else { throw APIError.invalidResponse }
                    continue
                }
                if !current.isRunning { phase = .finished; return }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            phase = .interrupted
            self.error = "Live updates stopped. The companion may still be cleaning up. Resume to reconnect to this archive. \(error.localizedDescription)"
        }
    }
}
