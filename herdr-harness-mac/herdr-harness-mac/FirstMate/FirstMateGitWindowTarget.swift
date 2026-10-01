import Foundation

struct FirstMateGitWindowTarget: Codable, Hashable, Identifiable, Sendable {
    let machineID: String
    let featureID: String
    /// Nil opens the feature’s recommended checkout with the checkout picker;
    /// a value pins that exact checkout.
    let workspaceID: String?
    var commitSHA: String? = nil

    var id: String {
        ([machineID, featureID] + (workspaceID.map { [$0] } ?? []) + (commitSHA.map { [$0] } ?? []))
            .joined(separator: "|")
    }
}

struct FirstMateGitCommitSelection: Hashable {
    let workspaceID: String
    let commitSHA: String
}
