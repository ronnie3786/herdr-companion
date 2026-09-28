import Foundation

struct FirstMateGitWindowTarget: Codable, Hashable, Identifiable, Sendable {
    let machineID: String
    let featureID: String
    let workspaceID: String
    var commitSHA: String? = nil

    var id: String { ([machineID, featureID, workspaceID] + (commitSHA.map { [$0] } ?? [])).joined(separator: "|") }
}

struct FirstMateGitCommitSelection: Hashable {
    let workspaceID: String
    let commitSHA: String
}
