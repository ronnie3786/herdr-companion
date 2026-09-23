import Foundation
import Observation

/// Failures the local comment store can surface to its owner.
///
/// Messages stay generic: a stored comment file path or a system error string
/// is never copied into UI text that could later travel off this Mac.
enum PRReviewCommentStoreError: LocalizedError, Equatable, Sendable {
    case storageUnavailable
    case unreadableStorage
    case unsupportedStorageVersion(Int)
    case corruptStorage
    case missingScope
    case invalidPRURL
    case reviewMismatch
    case blankBody
    case duplicateComment
    case invalidAnchor(PRReviewCommentAnchorProblem)
    case commentNotFound
    case staleEdit(currentVersion: Int)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Saved review comments are unavailable until the existing storage problem is resolved."
        case .unreadableStorage:
            "Saved review comments could not be read. The original file has been preserved."
        case .unsupportedStorageVersion:
            "Saved review comments use a newer storage format. The file has been preserved."
        case .corruptStorage:
            "Saved review comments could not be loaded. The original file has been preserved."
        case .missingScope:
            "A review comment needs a machine and review identifier."
        case .invalidPRURL:
            "A review comment needs a valid GitHub pull request link."
        case .reviewMismatch:
            "The selected diff belongs to a different review."
        case .blankBody:
            "Enter a comment before saving."
        case .duplicateComment:
            "A review comment with this identifier already exists."
        case .invalidAnchor:
            "The selected code no longer matches the loaded revision. Select it again to comment."
        case .commentNotFound:
            "This review comment no longer exists."
        case .staleEdit:
            "This review comment changed in another window. Reload it before saving."
        case .writeFailed:
            "The review comment could not be saved. Your text has been kept."
        }
    }
}

/// Private, Mac-local storage for saved PR Review comments.
///
/// The store is the single shared owner of comment records for main and
/// popped-out review windows. Records are scoped by configured machine and
/// review id, never by display labels, so two hosts that reuse a PR number or
/// review id can never share or overwrite each other's comments. Edits carry
/// the version they loaded and are rejected when newer text already exists.
///
/// Persistence is a versioned JSON envelope written atomically with
/// owner-only permissions. Nothing is pruned. A file that is unreadable,
/// corrupt, or from an unknown schema is preserved byte-for-byte and blocks
/// writes until the operator resolves it.
@MainActor
@Observable
final class PRReviewCommentStore {
    /// Versioned on-disk envelope. Unknown versions are never rewritten.
    struct PersistedFile: Codable, Equatable, Sendable {
        static let currentVersion = 1
        var version: Int
        var comments: [PRReviewComment]
    }

    private(set) var comments: [PRReviewComment] = []
    /// Set when existing storage could not be loaded. Every mutation is then
    /// refused so the preserved file is never overwritten.
    private(set) var loadError: PRReviewCommentStoreError?
    /// The most recent failed write, cleared by the next successful one.
    private(set) var writeError: PRReviewCommentStoreError?

    private let url: URL?

    /// - Parameters:
    ///   - url: An injectable storage location for tests and isolated demos.
    ///   - inMemory: Keeps the store fully in memory; useful for previews and
    ///     unit tests that do not exercise persistence.
    init(url: URL? = nil, inMemory: Bool = false) {
        if inMemory {
            self.url = nil
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = url ?? root.appending(path: "Herdr/PRReview/pr-review-comments-v1.json")
        }
        load()
    }

    // MARK: - Scoped listing

    func comments(machineID: String, reviewID: String) -> [PRReviewComment] {
        comments.filter { $0.machineID == machineID && $0.reviewID == reviewID }
    }

    func comments(machineID: String, reviewID: String, path: String) -> [PRReviewComment] {
        comments.filter {
            $0.machineID == machineID && $0.reviewID == reviewID && $0.anchor.path == path
        }
    }

    func comment(id: UUID) -> PRReviewComment? {
        comments.first { $0.id == id }
    }

    // MARK: - Insertion and editing

    /// Validates and records one new comment.
    ///
    /// The anchor must match the loaded diff's review and revision, name a
    /// file whose spans exist on their own sides, and carry the exact selected
    /// code. The PR URL is canonicalized before it is stored. The body itself
    /// is never trimmed or rewritten.
    @discardableResult
    func insert(
        _ draft: PRReviewCommentDraft,
        diff: PRReviewDiff,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> PRReviewComment {
        try requireWritable()
        guard !draft.machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.reviewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PRReviewCommentStoreError.missingScope }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PRReviewCommentStoreError.blankBody
        }
        guard let reference = PRReviewCommentLinks.reference(from: draft.prURL) else {
            throw PRReviewCommentStoreError.invalidPRURL
        }
        guard diff.reviewID == draft.reviewID else {
            throw PRReviewCommentStoreError.reviewMismatch
        }
        if let problem = draft.anchor.problem(against: diff) {
            throw PRReviewCommentStoreError.invalidAnchor(problem)
        }
        guard !comments.contains(where: { $0.id == id }) else {
            throw PRReviewCommentStoreError.duplicateComment
        }

        let comment = PRReviewComment(
            id: id,
            machineID: draft.machineID,
            reviewID: draft.reviewID,
            prURL: reference.canonicalURL.absoluteString,
            anchor: draft.anchor,
            body: draft.body,
            createdAt: createdAt,
            editVersion: 1
        )
        try mutate { comments.append(comment) }
        return comment
    }

    /// Replaces one comment's text.
    ///
    /// `editVersion` is the version the caller loaded. A different stored value
    /// means a newer edit already won, and nothing is written.
    @discardableResult
    func edit(
        id: UUID,
        body: String,
        expecting editVersion: Int,
        now: Date = Date()
    ) throws -> PRReviewComment {
        try requireWritable()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PRReviewCommentStoreError.blankBody
        }
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            throw PRReviewCommentStoreError.commentNotFound
        }
        let current = comments[index]
        guard current.editVersion == editVersion else {
            throw PRReviewCommentStoreError.staleEdit(currentVersion: current.editVersion)
        }

        var updated = current
        updated.body = body
        updated.updatedAt = max(now, current.updatedAt)
        updated.editVersion = current.editVersion + 1
        try mutate { comments[index] = updated }
        return updated
    }

    // MARK: - Storage

    private func requireWritable() throws {
        guard loadError == nil else { throw PRReviewCommentStoreError.storageUnavailable }
    }

    private func load() {
        guard let url else { return }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else {
            loadError = .unreadableStorage
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            loadError = .unreadableStorage
            return
        }

        let file: PersistedFile
        do {
            file = try JSONDecoder().decode(PersistedFile.self, from: data)
        } catch {
            loadError = .corruptStorage
            return
        }
        guard file.version == PersistedFile.currentVersion else {
            loadError = .unsupportedStorageVersion(file.version)
            return
        }
        guard Self.isStructurallyValid(file.comments) else {
            loadError = .corruptStorage
            return
        }
        comments = file.comments
    }

    /// Structural validation only. Records that decode but cannot describe a
    /// real saved comment mark the whole file as corrupt so nothing is
    /// silently dropped and the original bytes stay preserved.
    private static func isStructurallyValid(_ comments: [PRReviewComment]) -> Bool {
        guard Set(comments.map(\.id)).count == comments.count else { return false }
        return comments.allSatisfy { comment in
            !comment.machineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !comment.reviewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !comment.prURL.isEmpty
                && !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && comment.editVersion >= 1
                && !comment.anchor.path.isEmpty
                && !comment.anchor.code.isEmpty
                && !comment.anchor.spans.isEmpty
                && comment.anchor.spans.allSatisfy(\.isValid)
        }
    }

    /// Applies one mutation and persists it. A failed write restores the
    /// previous in-memory records so memory never claims a save that disk did
    /// not accept.
    private func mutate(_ change: () -> Void) throws {
        let previous = comments
        change()
        do {
            try persist()
            writeError = nil
        } catch let error as PRReviewCommentStoreError {
            comments = previous
            writeError = error
            throw error
        } catch {
            comments = previous
            writeError = .writeFailed
            throw PRReviewCommentStoreError.writeFailed
        }
    }

    private func persist() throws {
        guard let url else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(PersistedFile(
                version: PersistedFile.currentVersion,
                comments: comments
            ))
            // Prepare and permission the complete replacement before the
            // rename so a failed write never leaves disk ahead of memory.
            let temporary = directory.appending(path: ".pr-review-comments-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PRReviewCommentStoreError.writeFailed
        }
    }
}
