import Foundation

/// Associates results with the exact response that presented them. Never guess
/// from creation time: restored sessions, parallel tools and clock drift make
/// timestamps an unreliable response identity.
struct PiResponseArtifacts {
    let byTurnID: [String: [AgentResultArtifact]]
    let unassociated: [AgentResultArtifact]

    init(
        artifacts: [AgentResultArtifact],
        turns: [PiConversationTurn],
        machineID: String,
        sessionID: String?
    ) {
        var records = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var turnByArtifactID: [String: String] = [:]
        var turnsByToolCallID: [String: Set<String>] = [:]
        for turn in turns {
            for item in turn.items {
                guard case let .tool(tool) = item, tool.name == "present_result" else { continue }
                turnsByToolCallID[tool.callID, default: []].insert(turn.id)
                guard let saved = tool.resultArtifact else { continue }
                let artifact = saved.stamped(machineID: machineID)
                if let sessionID, let artifactSessionID = artifact.sessionID,
                   sessionID != artifactSessionID { continue }
                // The transcript itself proves response ownership, including
                // results from a headless run that was continued as this chat.
                records[artifact.id] = records[artifact.id] ?? artifact
                turnByArtifactID[artifact.id] = turn.id
            }
        }

        var associated: [String: [AgentResultArtifact]] = [:]
        var unmatched: [AgentResultArtifact] = []
        for artifact in records.values.sorted(by: PaneResultArtifacts.chronologicalOrder) {
            var turnID = turnByArtifactID[artifact.id]
            if turnID == nil, let callID = artifact.toolCallID,
               let candidates = turnsByToolCallID[callID], candidates.count == 1 {
                turnID = candidates.first
            }
            if let turnID {
                associated[turnID, default: []].append(artifact)
            } else {
                unmatched.append(artifact)
            }
        }
        byTurnID = associated
        unassociated = unmatched
    }
}
