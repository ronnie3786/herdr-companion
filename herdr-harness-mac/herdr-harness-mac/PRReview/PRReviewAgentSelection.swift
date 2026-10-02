import Foundation

struct PRReviewAgentGroup: Identifiable {
    let name: String
    let agents: [AgentRole]
    var id: String { name }
}

enum PRReviewAgentSelection {
    static let defaultAgentID = "pr-review-comprehensive"

    static func groups(_ agents: [AgentRole]) -> [PRReviewAgentGroup] {
        let grouped = Dictionary(grouping: agents, by: { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) })
        return grouped.keys.sorted {
            if $0.isEmpty { return true }
            if $1.isEmpty { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.map { name in
            PRReviewAgentGroup(name: name, agents: (grouped[name] ?? []).sorted {
                if $0.id == defaultAgentID { return true }
                if $1.id == defaultAgentID { return false }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
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
