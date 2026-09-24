import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The network seam for one execution companion's workspace launch. The real
/// `HerdrAPIClient` already speaks every requirement; tests inject a
/// deterministic fake without touching URLProtocol.
protocol HerdrHudWorkspaceLaunchClient: Sendable {
    func serverCapabilities() async throws -> ServerCapabilities
    func fetchWorkspaces() async throws -> WorkspacesResponse
    func uploadAttachment(
        workspaceID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse
    func createQuickPiSession(
        label: String,
        requestID: String,
        workspaceID: String?,
        tabID: String?,
        cwd: String?,
        sessionFile: String?,
        sessionID: String?,
        workspaceLabel: String?,
        tabLabel: String?,
        reuseNamedTab: Bool?,
        model: QuickPiSessionModel?,
        thinkingLevel: String?,
        focus: Bool?
    ) async throws -> QuickPiSessionResponse
    func sendPiPrompt(
        paneID: String,
        text: String,
        disposition: PiPromptDisposition,
        waitForIdle: Bool
    ) async throws
}

/// Immutable snapshot of everything one "create in main workspace" send needs.
/// The launcher never reads the HUD's mutable composer state, so a later
/// selection change cannot retarget an in-flight submission.
struct HerdrHudWorkspaceLaunchSubmission: Equatable, Sendable {
    /// The paired companion that must execute the chat.
    let machineID: String
    /// The companion's endpoint, normalized into the durable receipt.
    let endpoint: String
    /// Display-only; never participates in identity or fingerprints.
    let machineName: String?
    /// Exact raw workspace ID the user designated as their main workspace.
    let workspaceID: String
    /// Display-only; a rename never changes which workspace is targeted.
    let workspaceLabel: String?
    let requestID: String
    let label: String
    let folder: HerdrHudWorkingFolder
    let model: PiModelIdentity
    let thinkingLevel: PiThinkingLevel
    /// The user's prompt without attachment blocks. The launcher appends the
    /// uploaded paths in the shared composer's format.
    let prompt: String
    let attachments: [HerdrHudAttachment]

    init(
        machineID: String,
        endpoint: String,
        machineName: String? = nil,
        workspaceID: String,
        workspaceLabel: String? = nil,
        requestID: String,
        label: String,
        folder: HerdrHudWorkingFolder = .home,
        model: PiModelIdentity,
        thinkingLevel: PiThinkingLevel,
        prompt: String,
        attachments: [HerdrHudAttachment] = []
    ) {
        self.machineID = machineID
        self.endpoint = endpoint
        self.machineName = machineName
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.requestID = requestID
        self.label = label
        self.folder = folder
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.prompt = prompt
        self.attachments = attachments
    }

    /// Stable content identity for the durable receipt. Display-only fields
    /// (machine name, workspace label) are deliberately excluded, so a rename
    /// cannot turn a retry into a conflict.
    var fingerprint: String {
        let values: [String] = [
            machineID,
            HerdrNotesSource.normalizedEndpoint(endpoint),
            workspaceID,
            requestID,
            label,
            folder.path,
            model.provider,
            model.id,
            thinkingLevel.rawValue,
            prompt,
            attachments.map { "\($0.filename):\($0.byteCount)" }.joined(separator: "\n"),
        ]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Durable ownership of one workspace launch. Only identifiers and a content
/// fingerprint are persisted: never the prompt, attachment data, or paths.
struct HerdrHudWorkspaceLaunchReceipt: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case creating
        case sending
        case sent
    }

    let requestID: String
    let fingerprint: String
    let machineID: String
    let endpoint: String
    let workspaceID: String
    var tabID: String?
    var paneID: String?
    var phase: Phase
    let createdAt: Date

    /// Machine-scoped pane identity once the companion confirmed a pane. It is
    /// retained even when prompt delivery is uncertain so the UI can open the
    /// existing chat instead of repeating work.
    var scopedPaneID: String? {
        guard let paneID, !paneID.isEmpty else { return nil }
        return MachineScopedID.compose(machineID: machineID, rawID: paneID)
    }
}

enum HerdrHudWorkspaceLaunchError: LocalizedError, Equatable {
    enum SubmissionProblem: Equatable {
        case missingIdentity
        case invalidRequestID
        case invalidModel
        case invalidFolder
        case emptyPrompt
        case tooManyAttachments(maximum: Int)
        case unsupportedAttachment(filename: String)
        case unreadableAttachment(filename: String)
        case attachmentTooLarge(filename: String)
        case attachmentsTooLarge(maximumBytes: Int64)
    }

    case invalidSubmission(SubmissionProblem)
    case unsupportedCompanion(machineName: String?)
    case workspaceUnavailable
    case conflictingRequest
    case alreadyInProgress
    case tooManyRequests
    case attachmentUploadFailed(filename: String, message: String)
    case createUnconfirmed(message: String)
    case promptUnconfirmed(receipt: HerdrHudWorkspaceLaunchReceipt, message: String)
    case invalidCreateResponse

    var errorDescription: String? {
        switch self {
        case let .invalidSubmission(problem):
            switch problem {
            case .missingIdentity:
                "This chat no longer has a machine and main workspace. Choose a destination again."
            case .invalidRequestID:
                "This send no longer has a valid request ID. Start a new chat and try again."
            case .invalidModel:
                "The selected model is incomplete. Choose a model for this chat."
            case .invalidFolder:
                "The selected folder is not a valid path for this machine. Choose a folder again."
            case .emptyPrompt:
                "Write a message or attach a file before sending."
            case let .tooManyAttachments(maximum):
                "Attach up to \(maximum) files at a time."
            case let .unsupportedAttachment(filename):
                "\(filename) isn't a supported file type."
            case let .unreadableAttachment(filename):
                "Herdr can't read \(filename). Re-add it and try again."
            case let .attachmentTooLarge(filename):
                "\(filename) is larger than the 20 MB file limit."
            case let .attachmentsTooLarge(maximumBytes):
                "Attachments can total up to \(maximumBytes / (1024 * 1024)) MB per message."
            }
        case let .unsupportedCompanion(machineName):
            "\(machineName ?? "This companion") doesn't support creating a chat in a workspace yet. Update its companion server, then try again."
        case .workspaceUnavailable:
            "The main workspace is no longer on this machine. Choose another workspace for this chat."
        case .conflictingRequest:
            "This request ID was already used with different content. Start a new chat rather than resending."
        case .alreadyInProgress:
            "This chat is already being created."
        case .tooManyRequests:
            "Herdr is already starting several chats. Try again after they finish starting."
        case let .attachmentUploadFailed(filename, message):
            "Couldn't upload \(filename): \(message)"
        case let .createUnconfirmed(message):
            "Herdr couldn't confirm whether the chat was created in the main workspace. Check that workspace before trying again. The first message was not sent. \(message)"
        case let .promptUnconfirmed(_, message):
            "A chat was created in the main workspace, but Herdr couldn't confirm its first message was sent. Open that chat and check it before sending again. \(message)"
        case .invalidCreateResponse:
            "The companion's reply didn't identify a pane in the requested workspace. Check the workspace before trying again. The first message was not sent."
        }
    }

    /// The confirmed pane identity when one is known, so callers can offer
    /// "Open chat" instead of a blind retry.
    var confirmedReceipt: HerdrHudWorkspaceLaunchReceipt? {
        if case let .promptUnconfirmed(receipt, _) = self { return receipt }
        return nil
    }
}

/// Creates a fresh Pi chat directly in an explicitly designated main
/// workspace. Ownership is recorded before every side effect and an uncertain
/// prompt is never repeated automatically.
@MainActor
@Observable
final class HerdrHudWorkspaceLauncher {
    nonisolated static let requiredCapability = "quick-session-launch-options-v1"
    nonisolated static let maximumConcurrentLaunches = 8
    nonisolated static let retainedSentReceipts = 512

    private(set) var activeRequestIDs: Set<String> = []
    @ObservationIgnored private var receipts: [String: HerdrHudWorkspaceLaunchReceipt]
    @ObservationIgnored private let client: any HerdrHudWorkspaceLaunchClient
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var loadError: Error?

    init(
        client: any HerdrHudWorkspaceLaunchClient,
        storeURL: URL = HerdrHudWorkspaceLauncher.defaultStoreURL
    ) {
        self.client = client
        self.storeURL = storeURL
        receipts = [:]
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                receipts = try JSONDecoder().decode(
                    [String: HerdrHudWorkspaceLaunchReceipt].self,
                    from: Data(contentsOf: storeURL)
                )
            } catch {
                loadError = error
            }
        }
    }

    func receipt(for requestID: String) -> HerdrHudWorkspaceLaunchReceipt? {
        receipts[requestID]
    }

    /// Preflights the immutable snapshot, then creates and prompts exactly
    /// once. Returns the confirmed receipt on success; a prompt-delivery
    /// failure throws an error carrying the same confirmed pane identity.
    @discardableResult
    func launch(
        _ submission: HerdrHudWorkspaceLaunchSubmission
    ) async throws -> HerdrHudWorkspaceLaunchReceipt {
        if let loadError { throw loadError }
        try Self.validate(submission)

        let endpoint = HerdrNotesSource.normalizedEndpoint(submission.endpoint)
        let fingerprint = submission.fingerprint

        if activeRequestIDs.contains(submission.requestID) {
            throw HerdrHudWorkspaceLaunchError.alreadyInProgress
        }
        if let existing = receipts[submission.requestID] {
            guard existing.fingerprint == fingerprint,
                  existing.machineID == submission.machineID,
                  existing.endpoint == endpoint,
                  existing.workspaceID == submission.workspaceID
            else { throw HerdrHudWorkspaceLaunchError.conflictingRequest }
            switch existing.phase {
            case .sent:
                return existing
            case .sending:
                guard let paneID = existing.paneID, !paneID.isEmpty else {
                    throw HerdrHudWorkspaceLaunchError.createUnconfirmed(message: "The earlier reply was incomplete.")
                }
                throw HerdrHudWorkspaceLaunchError.promptUnconfirmed(
                    receipt: existing,
                    message: "The earlier send was not confirmed."
                )
            case .creating:
                guard existing.paneID == nil else {
                    throw HerdrHudWorkspaceLaunchError.promptUnconfirmed(
                        receipt: existing,
                        message: "The earlier send was not confirmed."
                    )
                }
                // The create is idempotent for one request ID, so an unfinished
                // create may be retried. The prompt was never attempted.
            }
        }
        guard activeRequestIDs.count < Self.maximumConcurrentLaunches else {
            throw HerdrHudWorkspaceLaunchError.tooManyRequests
        }
        activeRequestIDs.insert(submission.requestID)
        defer { activeRequestIDs.remove(submission.requestID) }

        // Preflight capability and the exact target before any mutation. An
        // older companion learns it must be updated without receiving fields
        // it cannot understand.
        let capabilities = try await client.serverCapabilities()
        guard capabilities.supportsQuickSessionLaunchOptions else {
            throw HerdrHudWorkspaceLaunchError.unsupportedCompanion(machineName: submission.machineName)
        }
        let topology = try await client.fetchWorkspaces()
        guard topology.ok,
              topology.workspaces.contains(where: { $0.workspaceID == submission.workspaceID })
        else {
            throw HerdrHudWorkspaceLaunchError.workspaceUnavailable
        }

        var receipt = receipts[submission.requestID] ?? HerdrHudWorkspaceLaunchReceipt(
            requestID: submission.requestID,
            fingerprint: fingerprint,
            machineID: submission.machineID,
            endpoint: endpoint,
            workspaceID: submission.workspaceID,
            tabID: nil,
            paneID: nil,
            phase: .creating,
            createdAt: .now
        )
        try record(receipt)

        let attachmentPaths = try await uploadAttachments(
            submission.attachments,
            workspaceID: submission.workspaceID
        )
        let prompt = Self.composedPrompt(base: submission.prompt, attachmentPaths: attachmentPaths)

        let response: QuickPiSessionResponse
        do {
            response = try await client.createQuickPiSession(
                label: submission.label,
                requestID: submission.requestID,
                workspaceID: submission.workspaceID,
                tabID: nil,
                cwd: submission.folder.path,
                sessionFile: nil,
                sessionID: nil,
                workspaceLabel: nil,
                tabLabel: nil,
                reuseNamedTab: false,
                model: QuickPiSessionModel(submission.model),
                thinkingLevel: submission.thinkingLevel.rawValue,
                focus: false
            )
        } catch {
            throw HerdrHudWorkspaceLaunchError.createUnconfirmed(message: error.localizedDescription)
        }
        guard response.requestID == submission.requestID,
              !response.tabID.isEmpty,
              !response.paneID.isEmpty,
              response.workspaceID == submission.workspaceID
        else {
            throw HerdrHudWorkspaceLaunchError.invalidCreateResponse
        }

        receipt.tabID = response.tabID
        receipt.paneID = response.paneID
        receipt.phase = .sending
        do {
            try record(receipt)
        } catch {
            // The pane exists; never send without durable ownership, and never
            // let the caller lose the confirmed identity.
            throw HerdrHudWorkspaceLaunchError.promptUnconfirmed(
                receipt: receipt,
                message: "Herdr could not save the launch receipt: \(error.localizedDescription)"
            )
        }

        do {
            try await client.sendPiPrompt(
                paneID: response.paneID,
                text: prompt,
                disposition: .prompt,
                waitForIdle: false
            )
        } catch {
            throw HerdrHudWorkspaceLaunchError.promptUnconfirmed(
                receipt: receipt,
                message: error.localizedDescription
            )
        }

        receipt.phase = .sent
        do {
            try record(receipt)
        } catch {
            // The prompt was accepted, but ownership could not be finalized.
            // The durable receipt still holds the confirmed pane, so a retry
            // can only open/check the chat, never send again.
            throw HerdrHudWorkspaceLaunchError.promptUnconfirmed(
                receipt: receipt,
                message: "Herdr could not save the launch receipt: \(error.localizedDescription)"
            )
        }
        return receipt
    }

    /// Matches the shared composer's attachment convention: one
    /// ``Attachment: `path` `` line per uploaded file, after the prompt.
    static func composedPrompt(base: String, attachmentPaths: [String]) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = attachmentPaths.map { "Attachment: `\($0)`" }.joined(separator: "\n")
        return [base, block].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func uploadAttachments(
        _ attachments: [HerdrHudAttachment],
        workspaceID: String
    ) async throws -> [String] {
        var paths: [String] = []
        for attachment in attachments {
            let response: AttachmentUploadResponse
            do {
                response = try await client.uploadAttachment(
                    workspaceID: workspaceID,
                    fileURL: attachment.url,
                    contentType: Self.contentType(for: attachment.url)
                )
            } catch {
                throw HerdrHudWorkspaceLaunchError.attachmentUploadFailed(
                    filename: attachment.filename,
                    message: error.localizedDescription
                )
            }
            guard response.ok, let uploaded = response.attachment, !uploaded.path.isEmpty else {
                throw HerdrHudWorkspaceLaunchError.attachmentUploadFailed(
                    filename: attachment.filename,
                    message: "the companion didn't confirm the upload"
                )
            }
            paths.append(uploaded.path)
        }
        return paths
    }

    private static func validate(_ submission: HerdrHudWorkspaceLaunchSubmission) throws {
        guard !submission.machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !submission.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !submission.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submission.workspaceID.utf8.count <= 512,
              !submission.workspaceID.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(.missingIdentity)
        }
        let requestID = submission.requestID
        guard !requestID.isEmpty,
              requestID.utf8.count <= 128,
              !requestID.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(.invalidRequestID)
        }
        guard HerdrHudNewChatPolicy.isComplete(submission.model) else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(.invalidModel)
        }
        guard HerdrHudWorkingFolder.normalizedPath(submission.folder.path) != nil else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(.invalidFolder)
        }
        guard !submission.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !submission.attachments.isEmpty
        else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(.emptyPrompt)
        }
        guard submission.attachments.count <= HerdrHudSession.maxAttachments else {
            throw HerdrHudWorkspaceLaunchError.invalidSubmission(
                .tooManyAttachments(maximum: HerdrHudSession.maxAttachments)
            )
        }

        var totalBytes: Int64 = 0
        for attachment in submission.attachments {
            guard HerdrAttachmentTypes.isAllowed(attachment.url) else {
                throw HerdrHudWorkspaceLaunchError.invalidSubmission(
                    .unsupportedAttachment(filename: attachment.filename)
                )
            }
            let accessed = attachment.url.startAccessingSecurityScopedResource()
            defer { if accessed { attachment.url.stopAccessingSecurityScopedResource() } }
            guard let values = try? attachment.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0
            else {
                throw HerdrHudWorkspaceLaunchError.invalidSubmission(
                    .unreadableAttachment(filename: attachment.filename)
                )
            }
            guard Int64(fileSize) <= AttachmentPolicy.maximumFileBytes else {
                throw HerdrHudWorkspaceLaunchError.invalidSubmission(
                    .attachmentTooLarge(filename: attachment.filename)
                )
            }
            totalBytes += Int64(fileSize)
            guard totalBytes <= HerdrHudSession.maxCombinedAttachmentBytes else {
                throw HerdrHudWorkspaceLaunchError.invalidSubmission(
                    .attachmentsTooLarge(maximumBytes: HerdrHudSession.maxCombinedAttachmentBytes)
                )
            }
        }
    }

    private func record(_ receipt: HerdrHudWorkspaceLaunchReceipt) throws {
        var updated = receipts
        updated[receipt.requestID] = receipt
        // Retain the most recent completed launches. Unfinished receipts are
        // never evicted automatically, because replay could duplicate work.
        let completed = updated.values.filter { $0.phase == .sent }
            .sorted { $0.createdAt > $1.createdAt }
        for old in completed.dropFirst(Self.retainedSentReceipts) {
            updated.removeValue(forKey: old.requestID)
        }
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(updated).write(to: storeURL, options: .atomic)
        receipts = updated
    }

    private static func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static var defaultStoreURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "Herdr/HudWorkspaceLaunches.json")
    }
}
