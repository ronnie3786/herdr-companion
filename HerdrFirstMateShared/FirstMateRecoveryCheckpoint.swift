import Foundation

struct FirstMateRecoveryCheckpoint: Codable, Equatable, Sendable {
    var assignmentID: String?
    var generation: Int?
    var observedAt: String?
    var nativeSessionID: String?
    var workspacePath: String?
    var head: String?
    var branch: String?
    var workingTreeStatus: String?
    var statusTruncated: Bool?
    var handoffDocumentID: String?
    var workspaceObservation: String?
    var backupPath: String? = nil
    var backupSHA256: String? = nil
    var currentPosition: FirstMateProgress? = nil

    enum CodingKeys: String, CodingKey {
        case generation, head, branch
        case assignmentID = "assignment_id", observedAt = "observed_at"
        case nativeSessionID = "native_session_id", workspacePath = "workspace_path"
        case workingTreeStatus = "working_tree_status", statusTruncated = "status_truncated"
        case handoffDocumentID = "handoff_document_id", workspaceObservation = "workspace_observation"
        case backupPath = "backup_path", backupSHA256 = "backup_sha256", currentPosition = "current_position"
    }
}
