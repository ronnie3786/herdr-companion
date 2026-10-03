import Foundation

struct PRReviewAgentGroup: Identifiable {
    let id: String
    let name: String
    let agents: [AgentRole]
}

enum PRReviewAgentSelection {
    static let defaultAgentID = "pr-review-comprehensive"

    /// Saved teams group by ID, so two teams never merge because of a shared name.
    /// Companions without saved teams only provide the name.
    static func groups(_ agents: [AgentRole]) -> [PRReviewAgentGroup] {
        let grouped = Dictionary(grouping: agents, by: teamKey)
        return grouped.map { key, members in
            PRReviewAgentGroup(id: key, name: key.isEmpty ? "" : members[0].group.trimmingCharacters(in: .whitespacesAndNewlines),
                               agents: members.sorted {
                if $0.id == defaultAgentID { return true }
                if $1.id == defaultAgentID { return false }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }.sorted {
            if $0.id.isEmpty { return true }
            if $1.id.isEmpty { return false }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func teamKey(_ agent: AgentRole) -> String {
        if let teamID = agent.teamId { return teamID.isEmpty ? "" : "team:" + teamID }
        let name = agent.group.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : "name:" + name
    }

    static func toggling(_ ids: Set<String>, in selection: Set<String>) -> Set<String> {
        ids.isSubset(of: selection) ? selection.subtracting(ids) : selection.union(ids)
    }

    static func initialSelection(agents: [AgentRole], saved: [String]?) -> Set<String> {
        let available = Set(agents.map(\.id))
        if let saved { return Set(saved).intersection(available) }
        return available.contains(defaultAgentID) ? [defaultAgentID] : []
    }
}
