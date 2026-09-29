import Foundation

/// Window-local reply progress. The fleet's own `isWorkingOnReply` also feeds
/// `workingOnReply` when projecting a conversation; a local send receipt or
/// queued echo bridges the interval before the fleet summary catches up.
enum FirstMateReplyProgress {
    static func isLocalReplyPending(
        outgoing: [FirstMateOutgoingMessage],
        snapshot: FirstMateSnapshot?,
        hostFeatureUpdatedAt: String?,
        fleetLatestFirstMateMessageID: String?
    ) -> Bool {
        // An in-flight request is local evidence even before a receipt or snapshot.
        // Once accepted, a receipt alone cannot keep an unselected row working
        // after the fleet has reported newer activity or a new First Mate reply.
        if outgoing.contains(where: { $0.state.isPending }) { return true }
        guard let snapshot else { return false }

        return outgoing.contains { entry in
            guard entry.state.isAcceptedAwaitingSnapshot,
                  hostFeatureUpdatedAt.map({ !isNewer($0, than: snapshot.feature.updatedAt) }) ?? true,
                  fleetLatestFirstMateMessageID.map({ entry.baselineMessageIDs.contains($0) }) ?? true
            else { return false }

            guard !snapshot.messages.contains(where: {
                $0.role == "assistant" && $0.isConversation && !entry.baselineMessageIDs.contains($0.id)
            }) else { return false }
            let echoes = snapshot.messages.filter { message in
                message.isConversation
                    && FirstMateTranscriptLayout.speaker(for: message) == .user
                    && !entry.baselineMessageIDs.contains(message.id)
            }
            // The real send endpoint returns only a singular message receipt;
            // the cached conversation is not refreshed until this chat is selected.
            return echoes.isEmpty || echoes.contains { $0.status == "queued" || $0.status == "processing" }
        }
    }

    private static func isNewer(_ candidate: String, than existing: String) -> Bool {
        guard let candidateDate = HerdrTimestamp.date(from: candidate),
              let existingDate = HerdrTimestamp.date(from: existing) else {
            // Unknown ordering cannot safely extend an accepted local bridge.
            return candidate != existing
        }
        return candidateDate > existingDate
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
