import Foundation

/// How the chat window lays a feature's conversation out: who speaks each
/// bubble, where groups start and end, where days change, which documents get
/// a file card, and which suggested replies show. Pure, so it is unit tested.
enum FirstMateTranscriptLayout {
    enum Speaker: Hashable, Sendable {
        case user
        case firstMate
        /// A crew agent, by assignment id.
        case agent(String)
    }

    struct Row: Identifiable, Equatable, Sendable {
        var message: FirstMateMessage
        var speaker: Speaker
        /// Shows the speaker's name.
        var isFirstInGroup: Bool
        /// Shows the avatar and the tail corner.
        var isLastInGroup: Bool
        /// "Today", "Yesterday", or a date when this message starts a new day.
        var dayLabel: String?
        var additionalReplies: [FirstMateMessage] = []
        var isPendingDecision = false

        var id: String { message.id }
    }

    /// A partially refreshed companion may report a reply before its user
    /// echo. Keep the still-local user row before newly reported replies;
    /// canonical server identity and order take over once the echo arrives.
    @MainActor static func orderedMessages(store: FirstMateStore, snapshot: FirstMateSnapshot) -> [FirstMateMessage] {
        var messages = store.conversationMessages(for: snapshot)
        for outgoing in store.outgoingMessages(for: snapshot.feature.id) {
            guard let localIndex = messages.firstIndex(where: { $0.id == outgoing.id }),
                  let replyIndex = messages[..<localIndex].firstIndex(where: {
                      $0.role == "assistant" && !outgoing.baselineMessageIDs.contains($0.id)
                  }) else { continue }
            let local = messages.remove(at: localIndex)
            messages.insert(local, at: replyIndex)
        }
        return messages
    }

    /// Speculative working ends on a failed send or when a real reply has
    /// arrived; existing server-reported queued work remains independent.
    @MainActor static func isAwaitingReply(store: FirstMateStore, snapshot: FirstMateSnapshot) -> Bool {
        store.outgoingMessages(for: snapshot.feature.id).contains { outgoing in
            (outgoing.state.isPending || outgoing.state.isAcceptedAwaitingSnapshot)
                && !snapshot.messages.contains(where: {
                    $0.role == "assistant" && $0.isConversation && !outgoing.baselineMessageIDs.contains($0.id)
                })
                && store.isAwaitingSendResolution(featureID: snapshot.feature.id)
        }
    }

    static func speaker(for message: FirstMateMessage) -> Speaker {
        if message.role == "user" || message.role == "human" { return .user }
        if let assignmentID = message.assignmentID, !assignmentID.isEmpty { return .agent(assignmentID) }
        return .firstMate
    }

    /// Groups consecutive messages from one speaker within one day. The typing
    /// bubble joins a First Mate group, so with `typing` the last First Mate
    /// bubble gives up its avatar and tail to it.
    static func rows(for messages: [FirstMateMessage], typing: Bool = false,
                     pendingDecisionMessageID: String? = nil, now: Date, calendar: Calendar) -> [Row] {
        let entries = FirstMateConversationEntry.make(messages: messages)
        let messages = entries.map(\.message)
        let days = messages.map { HerdrTimestamp.date(from: $0.createdAt).map { calendar.startOfDay(for: $0) } }
        var rows: [Row] = []
        for (index, message) in messages.enumerated() {
            let speaker = speaker(for: message)
            let newDay = index == 0 || days[index] != days[index - 1]
            let previous = index > 0 ? rows[index - 1] : nil
            let startsGroup = newDay || previous?.speaker != speaker
            if startsGroup, index > 0 { rows[index - 1].isLastInGroup = true }
            let dayLabel: String? = newDay
                ? HerdrTimestamp.date(from: message.createdAt).map { FirstMateChatTime.dayLabel(for: $0, now: now, calendar: calendar) }
                : nil
            rows.append(Row(message: message, speaker: speaker, isFirstInGroup: startsGroup, isLastInGroup: false,
                            dayLabel: dayLabel, additionalReplies: entries[index].additionalReplies,
                            isPendingDecision: message.id == pendingDecisionMessageID))
        }
        if !rows.isEmpty {
            rows[rows.count - 1].isLastInGroup = !(typing && rows[rows.count - 1].speaker == .firstMate)
        }
        return rows
    }

    /// Apply compact-surface limits after canonical turn grouping, so cutting
    /// old history cannot leave a checkpoint's closing question on its own.
    static func recentRows(for messages: [FirstMateMessage], limit: Int, typing: Bool = false,
                           pendingDecisionMessageID: String? = nil, now: Date, calendar: Calendar) -> [Row] {
        var recent = Array(rows(for: messages, typing: typing, pendingDecisionMessageID: pendingDecisionMessageID,
                                now: now, calendar: calendar).suffix(max(0, limit)))
        if !recent.isEmpty {
            recent[0].isFirstInGroup = true
            recent[0].dayLabel = HerdrTimestamp.date(from: recent[0].message.createdAt)
                .map { FirstMateChatTime.dayLabel(for: $0, now: now, calendar: calendar) }
        }
        return recent
    }

    /// What re-runs read marking. The fleet's read state is part of it: the
    /// transcript usually shows a reply before the fleet reports the chat
    /// unread, and marking then is a no-op, so the flip to unread (or a newer
    /// First Mate reply) must mark again while the newest message is on screen.
    struct ReadKey: Equatable, Sendable {
        var followsLatest: Bool
        var isKey: Bool
        var newest: String?
        var isUnread: Bool?
        var latestFirstMateMessageID: String?

        init(followsLatest: Bool, isKey: Bool, newest: String?, conversation: FirstMateConversation?) {
            self.followsLatest = followsLatest
            self.isKey = isKey
            self.newest = newest
            isUnread = conversation?.isUnread
            latestFirstMateMessageID = conversation?.latestFirstMateMessageID
        }
    }

    /// Whether the typing bubble starts its own group (shows "First Mate").
    static func typingStartsGroup(_ rows: [Row]) -> Bool {
        rows.last?.speaker != .firstMate
    }

    /// Each document's card shows once, on the earliest reply (First Mate's or
    /// an agent's) that names its title as whole words.
    static func fileCards(messages: [FirstMateMessage], documents: [FirstMateDocument]) -> [String: [FirstMateDocument]] {
        var cards: [String: [FirstMateDocument]] = [:]
        var shown = Set<String>()
        for message in messages where speaker(for: message) != .user {
            for document in documents where !shown.contains(document.id) && containsWholeWords(document.title, in: message.text) {
                shown.insert(document.id)
                cards[message.id, default: []].append(document)
            }
        }
        return cards
    }

    static func containsWholeWords(_ phrase: String, in text: String) -> Bool {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return false }
        var searchStart = text.startIndex
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
        while searchStart < text.endIndex,
              let found = text.range(of: phrase, options: .literal, range: searchStart..<text.endIndex) {
            searchStart = found.upperBound
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            let leadingOK = before.map { !(isWord($0) && isWord(phrase.first!)) } ?? true
            let trailingOK = after.map { !(isWord($0) && isWord(phrase.last!)) } ?? true
            if leadingOK && trailingOK { return true }
        }
        return false
    }

    /// Suggested replies: the newest message's skim `reply` blocks, only when
    /// it is First Mate's, the conversation needs you, and nothing is typing.
    /// Choices are never invented here.
    static func suggestedReplies(messages: [FirstMateMessage], needsYou: Bool, isTyping: Bool) -> [String] {
        let messages = FirstMateConversationEntry.make(messages: messages).map(\.message)
        guard needsYou, !isTyping, let newest = messages.last, speaker(for: newest) == .firstMate,
              let reader = FirstMateSkimReader.cached(skim: newest.skim, reply: newest.text, owner: newest.id) else { return [] }
        return reader.replies.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Something is being worked on for this chat: a send in flight, a queued
    /// or processing message of yours, or the companion reporting a reply.
    static func isTyping(messages: [FirstMateMessage], isSending: Bool, isWorkingOnReply: Bool) -> Bool {
        isSending || isWorkingOnReply || messages.contains {
            speaker(for: $0) == .user && ($0.status == "queued" || $0.status == "processing")
        }
    }
}
