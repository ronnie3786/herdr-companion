import Foundation

/// Phone presentation gates, independent of rendering and offscreen test hosts.
enum FirstMateMobileTranscriptPolicy {
    /// Published by the transcript's layout observation, not its parent body.
    /// Message content and disclosure projection fence old bottom geometry.
    struct ReadLayout: Equatable {
        var storeID: ObjectIdentifier
        var lifecycle: FirstMateStore.LifecycleIdentity
        var messages: [FirstMateMessage]
        var displayedServerIDs: Set<String>
        var expandedReplies: Set<String> = []
        var followsLatest: Bool
    }
    struct ReadAttempt: Equatable {
        var messageID: String
        var layout: ReadLayout
        var retryAt: Date?
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

    static func readMessage(conversation: FirstMateConversation?, visibility: Visibility,
                            messages: [FirstMateMessage], layout: ReadLayout?, optimisticMessageID: String? = nil) -> String? {
        guard visibility.permitsRead, let layout, layout.followsLatest, layout.messages == messages,
              let id = conversation?.latestFirstMateMessageID, !id.isEmpty,
              !FirstMateOutgoingMessage.isLocalID(id), layout.displayedServerIDs.contains(id),
              conversation?.isUnread == true || optimisticMessageID == id else { return nil }
        // Optimism keeps an existing task alive; trackRead still checks unread
        // before starting transport. It is eligibility, not cancellation identity.
        return id
    }

    static func displayedServerIDs(rows: [FirstMateTranscriptLayout.Row], expanded: Set<String>, featureID: String) -> Set<String> {
        var displayed: [FirstMateMessage] = []
        for row in rows {
            displayed.append(row.message)
            if expanded.contains(row.id) { displayed.append(contentsOf: row.additionalReplies) }
        }
        return Set(displayed.filter {
            $0.featureID == featureID && $0.isConversation && $0.role == "assistant" && !FirstMateOutgoingMessage.isLocalID($0.id)
        }.map(\.id))
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
            let owned = messages.filter { $0.featureID == snapshot.feature.id && $0.isConversation && !FirstMateOutgoingMessage.isLocalID($0.id) }
            let candidates: [FirstMateMessage]
            if let provenance = link.provenance.messageID {
                // Explicit provenance is authoritative, even when its message is
                // not loaded/eligible. Never relocate that card to a quoted URL.
                candidates = owned.filter { $0.id == provenance }
            } else {
                // Legacy links without provenance may use ONE exact Markdown
                // destination. Repeated URLs, titles and ordering are not identity.
                candidates = owned.filter {
                    (try? AttributedString(markdown: $0.text))?.runs.contains { $0.link?.absoluteString == link.url } == true
                }
            }
            if candidates.count == 1, let message = candidates.first { result[message.id, default: []].append(link) }
        }
        return result
    }
}
