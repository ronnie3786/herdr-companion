import Foundation

struct FirstMateGitWindowTarget: Codable, Hashable, Identifiable, Sendable {
    let machineID: String
    let featureID: String
    let workspaceID: String

    var id: String { [machineID, featureID, workspaceID].joined(separator: "|") }
}
