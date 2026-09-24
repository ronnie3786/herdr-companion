import Foundation

struct DashboardFeatureEntry: Identifiable, Equatable {
    let machineID: String
    let machineName: String
    let feature: FirstMateFeature
    var lastUpdated: Date?
    var hostError: String?

    var id: String { MachineScopedID.compose(machineID: machineID, rawID: feature.id) }
    var needsAttention: Bool { FirstMateAttention.needsHumanDecision(status: feature.status) }
    var isWorking: Bool { ["running", "coordinating", "recovering"].contains(feature.status) }
    var summary: FirstMateDashboardSummary? { feature.dashboardSummary }
    var isActive: Bool { !feature.isArchived && !["completed", "cancelled", "archived"].contains(feature.status) }

    private var rank: Int {
        if feature.status == "awaiting_direction" { return 0 }
        if feature.status == "blocked" { return 1 }
        return isWorking ? 2 : 3
    }

    static func ordered(_ entries: [Self], focusMode: Bool = false, query: String = "") -> [Self] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return entries.filter {
            $0.isActive && (!focusMode || $0.needsAttention) && seen.insert($0.id).inserted
                && (search.isEmpty || [$0.feature.title, $0.feature.goal, $0.feature.workItemID ?? "", $0.machineName]
                    .contains { $0.localizedStandardContains(search) })
        }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let left = HerdrTimestamp.date(from: $0.feature.updatedAt) ?? .distantPast
            let right = HerdrTimestamp.date(from: $1.feature.updatedAt) ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
