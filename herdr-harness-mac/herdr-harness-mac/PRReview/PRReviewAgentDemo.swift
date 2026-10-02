import Foundation

/// Synthetic profiles for the app demo and native presentation checks.
enum PRReviewAgentDemo {
    static var agents: [AgentRole] {
        [profile(id: "pr-review-comprehensive", name: "Comprehensive", avatar: "review", builtin: true),
         profile(id: "catalog-data", name: "Data integrity", avatar: "data", group: "Catalog team"),
         profile(id: "catalog-interface", name: "Interface reviewer", avatar: "design", group: "Catalog team")]
    }

    private static func profile(id: String, name: String, avatar: String, group: String = "", builtin: Bool = false) -> AgentRole {
        AgentRole(id: id, builtin: builtin, locked: false, name: name, whenToUse: "", systemPrompt: "",
                  modelProfile: "default", allowDelegation: false, skillIds: [], purpose: "pr_review",
                  group: group, avatar: avatar)
    }

    static func snapshot() -> PRReviewSnapshot {
        PRReviewDemo.snapshot()
    }

    static func decorating(_ snapshot: PRReviewSnapshot) -> PRReviewSnapshot {
        var value = snapshot
        value.runs = zip(value.runs, agents).map { run, agent in
            var run = run
            run.agentID = agent.id
            run.agentName = agent.name
            run.agentAvatar = agent.avatar
            run.kind = "reviewer"
            run.reviewGeneration = 1
            run.baseSHA = value.review.baseSHA
            run.headSHA = value.review.headSHA
            return run
        }
        value.consolidation = PRReviewConsolidation(generation: 1, state: "waiting",
            baseSHA: value.review.baseSHA, headSHA: value.review.headSHA, documentIDs: [],
            inputRunIDs: value.runs.map(\.id))
        value.documents[0].runID = value.runs[0].id
        return value
    }
}
