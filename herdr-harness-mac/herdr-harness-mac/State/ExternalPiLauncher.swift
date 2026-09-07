import Foundation
import Observation

/// Records intent before each side effect. Ambiguous network failures never
/// resend prompts or create another session when the same request ID is opened.
@MainActor
@Observable
final class ExternalPiLauncher {
    struct Receipt: Codable, Equatable {
        enum Phase: String, Codable { case creating, sending, sent }
        let requestID: String
        let fingerprint: String
        let createdAt: Date
        var paneID: String?
        var phase: Phase
    }

    enum LaunchError: LocalizedError {
        case conflictingRequest
        case unconfirmed
        case tooManyRequests
        var errorDescription: String? {
            switch self {
            case .conflictingRequest: "This request ID was already used with different content. Give the new request a new request_id."
            case .unconfirmed: "Herdr could not confirm the earlier launch or prompt delivery. Check the existing session before trying again with a new request_id. The prompt was not sent again."
            case .tooManyRequests: "Herdr is already starting several sessions. Try again after they finish starting."
            }
        }
    }

    private(set) var activeRequestIDs: Set<String> = []
    @ObservationIgnored private var receipts: [String: Receipt]
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var loadError: Error?

    init(storeURL: URL = ExternalPiLauncher.defaultStoreURL) {
        self.storeURL = storeURL
        receipts = [:]
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: storeURL))
            } catch { loadError = error }
        }
    }

    /// The create closure resolves its target before making a network mutation.
    /// Returning a scoped pane ID keeps retries bound to the original Mac.
    func start(
        _ request: ExternalPiRequest,
        create: @MainActor () async throws -> String,
        send: @MainActor (String, String) async throws -> Void,
        openPane: @MainActor (String) -> Void
    ) async throws {
        if let loadError { throw loadError }
        if let receipt = receipts[request.requestID] {
            guard receipt.fingerprint == request.fingerprint else { throw LaunchError.conflictingRequest }
            if let paneID = receipt.paneID { openPane(paneID) }
            if activeRequestIDs.contains(request.requestID) || receipt.phase == .sent { return }
            throw LaunchError.unconfirmed
        }
        guard activeRequestIDs.count < 8 else { throw LaunchError.tooManyRequests }
        activeRequestIDs.insert(request.requestID)
        defer { activeRequestIDs.remove(request.requestID) }
        var receipt = Receipt(requestID: request.requestID, fingerprint: request.fingerprint,
                              createdAt: .now, paneID: nil, phase: .creating)
        try record(receipt)
        let paneID = try await create()
        receipt.paneID = paneID
        receipt.phase = .sending
        try record(receipt)
        openPane(paneID)
        try await send(paneID, request.composedPrompt)
        receipt.phase = .sent
        try record(receipt)
    }

    func hasReceipt(for requestID: String) -> Bool { receipts[requestID] != nil }

    private func record(_ receipt: Receipt) throws {
        var updated = receipts
        updated[receipt.requestID] = receipt
        // Retain the most recent 512 completed launches. Unconfirmed requests
        // are never evicted automatically, because replay could duplicate work.
        let completed = updated.values.filter { $0.phase == .sent }
            .sorted { $0.createdAt > $1.createdAt }
        for old in completed.dropFirst(512) { updated.removeValue(forKey: old.requestID) }
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: storeURL, options: .atomic)
        receipts = updated
    }

    private static var defaultStoreURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "Herdr/ExternalPiLaunches.json")
    }
}
