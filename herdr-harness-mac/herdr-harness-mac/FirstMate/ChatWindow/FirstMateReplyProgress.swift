import Foundation

/// Window-local reply progress. The fleet's own `isWorkingOnReply` also feeds
/// `workingOnReply` when projecting a conversation; a local echo bridges the
/// interval before the fleet summary catches up.
enum FirstMateReplyProgress {
    static func isLocalReplyPending(
        outgoing: [FirstMateOutgoingMessage],
        isAwaitingSendResolution: Bool,
        snapshot: FirstMateSnapshot?,
        hostFeatureUpdatedAt: String?,
        fleetLatestFirstMateMessageID: String?
    ) -> Bool {
        if isAwaitingSendResolution { return true }
        guard let snapshot else { return false }

        return outgoing.contains { entry in
            guard !entry.state.isFailure,
                  hostFeatureUpdatedAt.map({ $0 <= snapshot.feature.updatedAt }) ?? true,
                  fleetLatestFirstMateMessageID.map({ entry.baselineMessageIDs.contains($0) }) ?? true
            else { return false }

            return snapshot.messages.contains { message in
                message.isConversation
                    && FirstMateTranscriptLayout.speaker(for: message) == .user
                    && (message.status == "queued" || message.status == "processing")
                    && !entry.baselineMessageIDs.contains(message.id)
            }
        }
    }

    /// The fleet's `isWorkingOnReply` and local pending sends both request this
    /// presentation; neither changes the authoritative feature status.
    static func presenting(_ conversation: FirstMateConversation, workingOnReply: Bool) -> FirstMateConversation {
        guard workingOnReply, conversation.hudStatus != .done else { return conversation }
        var presented = conversation
        presented.hudStatus = .working
        presented.isWorkingOnReply = true
        return presented
    }
}
