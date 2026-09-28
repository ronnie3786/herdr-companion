import Foundation

/// One visible response with any closing replies retained behind a disclosure.
/// Group only explicit turn provenance, never wording or adjacent timestamps.
struct FirstMateConversationEntry: Identifiable, Equatable, Sendable {
    var message: FirstMateMessage
    var additionalReplies: [FirstMateMessage] = []
    var id: String { message.id }

    static func make(messages: [FirstMateMessage]) -> [Self] {
        let conversation = messages.filter(\.isConversation)
        var checkpoints: [Turn: String] = [:]
        for message in conversation where message.role == "assistant" && message.assignmentID == nil && message.metadata?.checkpoint == true {
            if let turnID = message.metadata?.turnID, !turnID.isEmpty {
                checkpoints[Turn(featureID: message.featureID, turnID: turnID)] = message.id
            }
        }
        var additional: [String: [FirstMateMessage]] = [:]
        var main: [FirstMateMessage] = []
        for message in conversation {
            if message.role == "assistant", message.assignmentID == nil, message.metadata?.checkpoint != true,
               let turnID = message.metadata?.inReplyTo, !turnID.isEmpty,
               let checkpointID = checkpoints[Turn(featureID: message.featureID, turnID: turnID)] {
                additional[checkpointID, default: []].append(message)
            } else {
                main.append(message)
            }
        }
        return main.map { Self(message: $0, additionalReplies: additional[$0.id] ?? []) }
    }

    private struct Turn: Hashable {
        let featureID: String
        let turnID: String
    }
}
