import Foundation

/// What First Mate Git opens: one feature on one machine, optionally pinned to
/// a checkout and a commit (a workflow commit receipt). Nil workspace means the
/// feature's recommended checkout with the checkout picker available.
struct FirstMateGitTarget: Identifiable, Hashable, Sendable {
    let feature: FirstMateFeatureTarget
    let featureTitle: String
    var workspaceID: String? = nil
    var commitSHA: String? = nil

    var id: String { [feature.machineID, feature.featureID, workspaceID ?? "", commitSHA ?? ""].joined(separator: "|") }
}
