import Foundation

struct AgentControlCachedReceipt: Equatable, Sendable {
    let command: AgentControlCommand
    let status: String
    let result: [String: PiJSONValue]?
    let error: AgentControlCommandError?
    /// Frozen at completion so a lost acknowledgement can be retried byte-for-
    /// byte even if the user navigates before the retry.
    let state: AgentControlUIState
}

struct AgentControlExecutionCache: Sendable {
    private var values: [String: AgentControlCachedReceipt] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    enum Lookup: Equatable, Sendable {
        case miss
        case hit(AgentControlCachedReceipt)
        case conflict
    }

    func lookup(_ command: AgentControlCommand) -> Lookup {
        guard let cached = values[command.requestId] else { return .miss }
        guard cached.command.action == command.action,
              cached.command.target == command.target,
              cached.command.parameters == command.parameters,
              cached.command.expectedRevision == command.expectedRevision else { return .conflict }
        return .hit(cached)
    }

    mutating func store(_ receipt: AgentControlCachedReceipt) {
        if values[receipt.command.requestId] == nil { order.append(receipt.command.requestId) }
        values[receipt.command.requestId] = receipt
        while order.count > limit {
            values[order.removeFirst()] = nil
        }
    }
}
