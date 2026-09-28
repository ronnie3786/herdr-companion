import SwiftUI

// MARK: - Pure layout

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

/// What your own bubble shows: the text without the dictation suffix (the
/// bubble says "Sent by voice" instead) and without `Attachment:` lines, which
/// become small chips. Display only; Copy keeps the message as sent.
struct FirstMateMessageDisplay: Equatable, Sendable {
    static let dictationSuffix = "(transcribed audio, please account for incorrect names or typos)"

    var body: String
    /// Attachment paths, in order.
    var attachments: [String]
    var isVoice: Bool

    static func parse(_ text: String) -> Self {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isVoice = false
        if remaining.hasSuffix(dictationSuffix) {
            isVoice = true
            remaining = String(remaining.dropLast(dictationSuffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var attachments: [String] = []
        var lines: [Substring] = []
        for line in remaining.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = attachmentPath(in: line) {
                attachments.append(path)
            } else {
                lines.append(line)
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(body: body, attachments: attachments, isVoice: isVoice)
    }

    /// `Attachment: `path`` (the composer's format), else nil.
    static func attachmentPath(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "Attachment: `"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("`"), trimmed.count > prefix.count + 1 else { return nil }
        let path = trimmed.dropFirst(prefix.count).dropLast()
        guard !path.isEmpty, !path.contains("`") else { return nil }
        return String(path)
    }

    static func fileName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// What VoiceOver reads for your bubble: the text, the attached file
    /// names, and whether it is queued or was sent by voice, leaving out
    /// empty parts.
    func accessibilityLabel(isQueued: Bool) -> String {
        var parts: [String] = []
        if !body.isEmpty { parts.append(body) }
        if !attachments.isEmpty {
            parts.append("attached " + attachments.map(Self.fileName(of:)).joined(separator: ", "))
        }
        if isQueued { parts.append("queued") }
        if isVoice { parts.append("sent by voice") }
        return "You: " + parts.joined(separator: ", ")
    }
}

// MARK: - Transcript

/// A feature's conversation as grouped bubbles, with the skim, feedback, file
/// cards, typing indicator, and read markers.
struct FirstMateChatTranscript: View {
    let session: FirstMateChatWindowSession
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let conversationID: FirstMateFleetFeatureID
    let isTyping: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var followsLatest = true
    @State private var feedbackEditor: FirstMateFeedbackEditorTarget?
    /// Only the clamped, whole-point bubble width is state, so resize frames
    /// that do not change it do not rebuild the transcript.
    @State private var bubbleMaxWidth: CGFloat = Self.bubbleMaxWidth(forWidth: 720)

    static let endID = "first-mate-chat-window-end"
    nonisolated static let maxContentWidth: CGFloat = 720
    nonisolated static let gutter: CGFloat = 24

    private var messages: [FirstMateMessage] { snapshot.messages.filter(\.isConversation) }

    nonisolated static func bubbleMaxWidth(forWidth width: CGFloat) -> CGFloat {
        let content = min(max(width - gutter * 2, 200), maxContentWidth)
        return min(content * 0.86, 560).rounded()
    }

    var body: some View {
        let messages = messages
        let rows = FirstMateTranscriptLayout.rows(for: messages, typing: isTyping,
            pendingDecisionMessageID: snapshot.pendingDecisionMessageID, now: .now, calendar: .current)
        let cards = FirstMateTranscriptLayout.fileCards(messages: messages, documents: snapshot.documents)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if let day = row.dayLabel {
                            FirstMateDayPill(label: day)
                                .padding(.top, 4)
                                .padding(.bottom, 8)
                        }
                        bubble(for: row, cards: cards[row.id] ?? [])
                            .padding(.top, row.isFirstInGroup ? (row.dayLabel == nil ? 14 : 6) : 3)
                        if !row.additionalReplies.isEmpty {
                            DisclosureGroup("Additional response from this turn") {
                                ForEach(FirstMateTranscriptLayout.rows(for: row.additionalReplies, now: .now, calendar: .current)) { reply in
                                    bubble(for: reply, cards: cards[reply.id] ?? [])
                                }
                            }
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                            .padding(.leading, FirstMateChatBubbleRow.avatarSize + FirstMateChatBubbleRow.avatarGap)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("first-mate-window-additional-replies-\(row.id)")
                        }
                    }
                    if isTyping {
                        let startsGroup = FirstMateTranscriptLayout.typingStartsGroup(rows)
                        FirstMateTypingRow(startsGroup: startsGroup)
                            .padding(.top, startsGroup ? 14 : 3)
                    }
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .environment(\.skimDisplayState, session.skimState(for: conversationID))
                .environment(\.skimScrollTo) { id in
                    withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
                }
                .padding(.top, 22)
                .padding(.bottom, 16)
                .padding(.horizontal, Self.gutter)
                .frame(maxWidth: Self.maxContentWidth + Self.gutter * 2)
                .frame(maxWidth: .infinity)
            }
            // Opens at the newest message and follows growth, but a short
            // conversation starts at the top like any chat.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .onGeometryChange(for: CGFloat.self) { Self.bubbleMaxWidth(forWidth: $0.size.width) } action: { bubbleMaxWidth = $0 }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                followsLatest = nearBottom
            }
            .onChange(of: messages.last?.id) { _, _ in
                if followsLatest { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .onChange(of: isTyping) { _, typing in
                if typing, followsLatest { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
        }
        .onAppear(perform: markRead)
        .onChange(of: FirstMateTranscriptLayout.ReadKey(
            followsLatest: followsLatest,
            isKey: controlActiveState == .key,
            newest: messages.last?.id,
            conversation: session.conversations.first { $0.id == conversationID }
        )) { _, _ in
            markRead()
        }
        .task(id: feedbackLoadID) { await loadFeedback() }
        .onChange(of: store.operationContext) { _, _ in feedbackEditor = nil }
        .sheet(item: $feedbackEditor) { target in
            FirstMateFeedbackEditor(store: store, target: target)
        }
    }

    /// Read when this window is key and the newest message is on screen.
    private func markRead() {
        session.markReadIfNeeded(
            featureID: conversationID.featureID,
            machineID: conversationID.machineID,
            newestMessageID: messages.last?.id,
            isKeyWindow: controlActiveState == .key,
            isAtBottom: followsLatest
        )
    }

    @ViewBuilder
    private func bubble(for row: FirstMateTranscriptLayout.Row, cards: [FirstMateDocument]) -> some View {
        let message = row.message
        let agent: FirstMateAssignment? = {
            guard case .agent(let id) = row.speaker else { return nil }
            return snapshot.assignments.first { $0.id == id }
        }()
        let feedback: FirstMateResponseFeedbackPresentation? = row.speaker == .user ? nil : .make(
            message: message,
            supported: store.feedbackSupported,
            writable: store.controlAvailable,
            isSaving: store.isSavingFeedback(featureID: message.featureID, messageID: message.id),
            record: store.feedback(for: message.featureID, messageID: message.id),
            saveErrorMessage: store.feedbackSaveError(featureID: message.featureID, messageID: message.id),
            hasConflict: store.feedbackConflict(featureID: message.featureID, messageID: message.id),
            isFeedbackLoaded: store.hasLoadedFeedback(for: message.featureID)
        )
        FirstMateChatBubbleRow(
            row: row,
            agent: agent,
            fileCards: cards.map { document in
                FirstMateFileCard.Model(
                    document: document,
                    from: document.assignmentID.flatMap { id in snapshot.assignments.first { $0.id == id }?.title }
                )
            },
            maxBubbleWidth: bubbleMaxWidth,
            feedback: feedback,
            feedbackActions: feedbackActions(for: message),
            openDocuments: { session.showInspector(.documents) }
        )
    }

    // MARK: Feedback (the same wiring as FirstMateChatView)

    private var feedbackLoadID: String {
        "\(snapshot.feature.id)|\(store.lifecycle.opaqueID)|\(store.feedbackSupported)"
    }

    private func loadFeedback() async {
        guard store.feedbackSupported else { return }
        let context = store.operationContext
        await store.loadFeedback(expectedContext: context)
        guard store.feedbackSupported else { return }
        await store.loadFeedbackCategories(expectedContext: context)
    }

    private func feedbackActions(for message: FirstMateMessage) -> FirstMateChatFeedbackActions {
        let context = store.operationContext
        let store = store
        return FirstMateChatFeedbackActions(
            rate: { rating in
                Task { await store.rateFeedback(rating, messageID: message.id, expectedContext: context) }
            },
            edit: { openFeedbackEditor(for: message, expectedContext: context) },
            remove: {
                Task { await store.saveFeedback(FirstMateFeedbackDraft(rating: nil), messageID: message.id, expectedContext: context) }
            },
            retry: {
                // A failed thumbs-up or Remove keeps its attempted draft, so
                // retry resubmits that exact payload and request identity.
                let draft = store.feedbackDraft(for: message.featureID, messageID: message.id)
                Task { await store.saveFeedback(draft, messageID: message.id, expectedContext: context) }
            },
            resolveConflict: {
                Task {
                    guard await store.resolveFeedbackConflict(messageID: message.id, expectedContext: context) else { return }
                    let draft = store.feedbackDraft(for: message.featureID, messageID: message.id)
                    await store.saveFeedback(draft, messageID: message.id, expectedContext: context)
                }
            }
        )
    }

    private func openFeedbackEditor(for message: FirstMateMessage, expectedContext: FirstMateStore.OperationContext) {
        let currentContext = store.operationContext
        guard expectedContext == currentContext,
              currentContext.matchesFeature(message.featureID),
              FirstMateFeedbackEligibility.isEligible(message),
              store.feedbackSupported else { return }
        if store.hasLoadedFeedback(for: message.featureID),
           let record = store.feedback(for: message.featureID, messageID: message.id),
           record.rating != .down {
            store.setFeedbackDraft(
                FirstMateFeedbackDraft(rating: .down, baseRevision: record.revision),
                for: message.featureID,
                messageID: message.id,
                expectedContext: currentContext
            )
        }
        feedbackEditor = FirstMateFeedbackEditorTarget(
            featureID: message.featureID,
            messageID: message.id,
            responseText: message.text,
            expectedContext: currentContext
        )
    }
}

/// The per-message feedback closures `FirstMateResponseFeedbackFooter` takes.
struct FirstMateChatFeedbackActions {
    var rate: @MainActor (FirstMateFeedbackRating) -> Void = { _ in }
    var edit: @MainActor () -> Void = {}
    var remove: @MainActor () -> Void = {}
    var retry: @MainActor () -> Void = {}
    var resolveConflict: @MainActor () -> Void = {}
}
