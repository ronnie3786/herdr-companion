import Foundation

/// Phone presentation gates, independent of rendering and offscreen test hosts.
enum FirstMateMobileTranscriptPolicy {
    /// Poll completion allows an eligible failed marker to retry, while the
    /// phone-owned store enforces its existing 8–180 second backoff.
    struct ReadAttempt: Equatable {
        var messageID: String?
        var poll: Date?
    }
    struct Visibility: Equatable {
        var appeared = false
        var activeScene = false
        var firstMateTab = false
        var topmost = false
        var covered = false
        var followsLatest = true
        var permitsRead: Bool { appeared && activeScene && firstMateTab && topmost && !covered && followsLatest }
    }

    static func isClosed(_ snapshot: FirstMateSnapshot?) -> Bool {
        ["completed", "cancelled"].contains(snapshot?.feature.status ?? "")
    }

    static func statusWord(snapshot: FirstMateSnapshot?, conversation: FirstMateConversation?) -> String {
        if isClosed(snapshot) { return snapshot?.feature.status == "cancelled" ? "Cancelled" : "Complete" }
        return conversation.map(FirstMateChatStatusStyle.word) ?? snapshot?.feature.status ?? "Loading"
    }

    static func replies(messages: [FirstMateMessage], snapshot: FirstMateSnapshot,
                        needsYou: Bool, isTyping: Bool) -> [String] {
        FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: needsYou && !isClosed(snapshot), isTyping: isTyping)
    }

    static func readMessage(conversation: FirstMateConversation?, visibility: Visibility) -> String? {
        guard visibility.permitsRead, conversation?.isUnread == true,
              let id = conversation?.latestFirstMateMessageID, !id.isEmpty,
              !FirstMateOutgoingMessage.isLocalID(id) else { return nil }
        return id
    }

    static func mentionCatalog(conversations: [FirstMateConversation], snapshot: FirstMateSnapshot, owner: FirstMateFeatureTarget) -> FirstMateMentionCatalog {
        guard snapshot.feature.id == owner.featureID else { return .init(entries: []) }
        var ownedSnapshot = snapshot
        ownedSnapshot.assignments = snapshot.assignments.filter { $0.featureID == owner.featureID }
        let catalog = FirstMateMentionCatalog(conversations: conversations.filter { $0.machineID == owner.machineID }, snapshot: ownedSnapshot)
        let groups = Dictionary(grouping: catalog.entries, by: \.name)
        return .init(entries: catalog.entries.filter { entry in
            Set((groups[entry.name] ?? []).map(\.target)).count == 1
        })
    }

    static func nearBottom(offset: Double, viewport: Double, content: Double, bottomInset: Double) -> Bool {
        viewport > 0 && content > 0 && offset + viewport >= content + bottomInset - 40
    }

    /// A card's identity comes from this exact snapshot's resources. Title
    /// association is allowed only when unique; identical titles never pick a
    /// first document. Internal handoff documents stay out of this collection.
    static func fileCards(messages: [FirstMateMessage], snapshot: FirstMateSnapshot) -> [String: [FirstMateDocument]] {
        let documents = snapshot.presentedDocuments.filter { $0.featureID == snapshot.feature.id }
        let groups = Dictionary(grouping: documents, by: \.title)
        return FirstMateTranscriptLayout.fileCards(messages: messages.filter { $0.featureID == snapshot.feature.id },
            documents: documents.filter { groups[$0.title]?.count == 1 })
    }

    static func linkCards(messages: [FirstMateMessage], snapshot: FirstMateSnapshot) -> [String: [FirstMateLink]] {
        var result: [String: [FirstMateLink]] = [:]
        for link in snapshot.links where link.featureID == snapshot.feature.id && link.isPullRequest && !link.isHidden && link.destination != nil {
            if let message = messages.first(where: {
                $0.featureID == snapshot.feature.id && ($0.id == link.provenance.messageID ||
                    ((try? AttributedString(markdown: $0.text))?.runs.contains { $0.link?.absoluteString == link.url } == true))
            }) { result[message.id, default: []].append(link) }
        }
        return result
    }
}
