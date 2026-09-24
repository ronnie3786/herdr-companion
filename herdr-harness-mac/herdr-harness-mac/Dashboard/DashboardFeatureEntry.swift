import Foundation

struct DashboardFeatureEntry: Identifiable, Equatable {
    let machineID: String
    let machineName: String
    let feature: FirstMateFeature
    var lastUpdated: Date?
    var hostError: String?
    /// Last meaningful activity, parsed once so ordering never parses inside a
    /// comparator. Older companions only report `updated_at`, which Pi
    /// telemetry keeps current.
    let activityDate: Date?
    /// Card text, prepared once per feature list change rather than per render.
    let title: String
    let preview: String?
    let attentionPrompt: String?

    init(machineID: String, machineName: String, feature: FirstMateFeature, lastUpdated: Date? = nil, hostError: String? = nil) {
        self.machineID = machineID
        self.machineName = machineName
        self.feature = feature
        self.lastUpdated = lastUpdated
        self.hostError = hostError
        activityDate = feature.dashboardSummary?.activityAt.flatMap(HerdrTimestamp.date)
            ?? HerdrTimestamp.date(from: feature.updatedAt)
        title = AgentBoardContent.displayTitle(feature.title, workItemID: feature.workItemID)
        let latest = feature.dashboardSummary?.latestMessage.map(AgentBoardProse.plainText(fromMarkdown:))
        preview = (latest?.isEmpty == false ? latest : nil)
            ?? (feature.goal.isEmpty ? nil : AgentBoardProse.plainText(fromMarkdown: feature.goal))
        let waiting = FirstMateAttention.needsHumanDecision(status: feature.status) || feature.dashboardSummary?.awaitingTurn == true
        attentionPrompt = waiting
            ? (feature.dashboardSummary?.needsUserPrompt ?? feature.dashboardSummary?.latestMessage)
                .map(AgentBoardProse.plainText(fromMarkdown:)) : nil
    }

    var id: String { MachineScopedID.compose(machineID: machineID, rawID: feature.id) }
    /// Waiting on a decision, or parked until a person takes their turn. The
    /// sidebar badge counts decisions only; these screens show both.
    var needsAttention: Bool { FirstMateAttention.needsHumanDecision(status: feature.status) || awaitingTurn }
    var awaitingTurn: Bool { feature.dashboardSummary?.awaitingTurn == true }
    var isWorking: Bool { ["running", "coordinating", "recovering"].contains(feature.status) && !awaitingTurn }
    var summary: FirstMateDashboardSummary? { feature.dashboardSummary }
    var isActive: Bool { !feature.isArchived && !["completed", "cancelled", "archived"].contains(feature.status) }

    private var rank: Int {
        if feature.status == "awaiting_direction" || awaitingTurn { return 0 }
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
            let left = $0.activityDate ?? .distantPast
            let right = $1.activityDate ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
