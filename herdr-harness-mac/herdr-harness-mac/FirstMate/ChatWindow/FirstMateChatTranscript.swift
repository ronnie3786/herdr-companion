import SwiftUI

// MARK: - Transcript

/// A feature's conversation as grouped bubbles, with the skim, feedback, file
/// cards, typing indicator, and read markers.
struct FirstMateChatTranscript: View {
    let session: FirstMateChatWindowSession
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let conversationID: FirstMateFleetFeatureID
    let isTyping: Bool
    var openDocuments: (() -> Void)? = nil
    var validateOwner: (@MainActor () -> Bool)? = nil

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var followsLatest = true
    @State private var earlierAnchor: String?
    @State private var transcriptClock = FirstMateTranscriptClock()
    @State private var fileCards = FirstMateTranscriptFileCards()
    @State private var feedbackEditor: FirstMateFeedbackEditorTarget?
    /// Only the clamped, whole-point bubble width is state, so resize frames
    /// that do not change it do not rebuild the transcript.
    @State private var bubbleMaxWidth: CGFloat = Self.bubbleMaxWidth(forWidth: 720)

    static let endID = "first-mate-chat-window-end"
    nonisolated static let maxContentWidth: CGFloat = 720
    nonisolated static let gutter: CGFloat = 24

    private var messages: [FirstMateMessage] { FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot) }

    nonisolated static func bubbleMaxWidth(forWidth width: CGFloat) -> CGFloat {
        let content = min(max(width - gutter * 2, 200), maxContentWidth)
        return min(content * 0.86, 560).rounded()
    }

    var body: some View {
        let messages = messages
        let rows = FirstMateTranscriptLayout.rows(for: messages, typing: isTyping,
            pendingDecisionMessageID: snapshot.pendingDecisionMessageID, now: transcriptClock.now, calendar: .current)
        let cardInput = FirstMateTranscriptFileCards.Input(messages: messages, documents: snapshot.documents)
        let cards = fileCards.cards
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.earlierMessageCursors[snapshot.feature.id] != nil {
                        Button(store.loadingEarlierMessages.contains(snapshot.feature.id) ? "Loading earlier messages…" : "Load earlier messages") {
                            earlierAnchor = rows.first?.id
                            followsLatest = false
                            Task { await store.loadEarlierMessages() }
                        }
                        .disabled(store.loadingEarlierMessages.contains(snapshot.feature.id))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .accessibilityIdentifier("first-mate-load-earlier-messages")
                    }
                    if let error = store.earlierMessagesErrors[snapshot.feature.id] {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
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
                                ForEach(FirstMateTranscriptLayout.rows(for: row.additionalReplies, now: transcriptClock.now, calendar: .current)) { reply in
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
                .environment(\.skimReplyContext, FirstMateSkimReplies.context(snapshot: snapshot, store: store, canControl: store.controlAvailable || store.isDemo, validateOwner: validateOwner))
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
            .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .onGeometryChange(for: CGFloat.self) { Self.bubbleMaxWidth(forWidth: $0.size.width) } action: { bubbleMaxWidth = $0 }
            .onChange(of: rows.first?.id) { _, _ in
                guard let anchor = earlierAnchor else { return }
                // A newly loaded checkpoint may group the former first reply
                // under Additional responses. Anchor its surviving container.
                let target = rows.first { $0.id == anchor || $0.additionalReplies.contains { $0.id == anchor } }?.id
                if let target { withAnimation(nil) { proxy.scrollTo(target, anchor: .top) } }
                earlierAnchor = nil
            }
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
        .modifier(FirstMateTranscriptClockLifecycle(clock: transcriptClock))
        .task(id: cardInput) { await fileCards.update(cardInput) }
        .onAppear(perform: markRead)
        .onChange(of: FirstMateTranscriptLayout.ReadKey(
            followsLatest: followsLatest,
            isKey: controlActiveState == .key,
            newest: store.newestServerMessageID(for: snapshot),
            conversation: session.conversations.first { $0.id == conversationID }
        )) { _, _ in
            markRead()
        }
        .task(id: feedbackLoadID) { await loadFeedback() }
        .onChange(of: store.operationContext) { _, _ in feedbackEditor = nil }
        .sheet(item: $feedbackEditor) { target in
            FirstMateFeedbackEditor(store: store, target: target, validateOwner: validateOwner)
        }
    }

    /// Read when this window is key and the newest message is on screen.
    private func markRead() {
        markReadIfVisible(isKeyWindow: controlActiveState == .key, isAtBottom: followsLatest)
    }

    /// Shared by the mounted transcript and focused read-ownership tests.
    func markReadIfVisible(isKeyWindow: Bool, isAtBottom: Bool) {
        guard validateOwner?() ?? true else { return }
        session.markReadIfNeeded(
            featureID: conversationID.featureID,
            machineID: conversationID.machineID,
            newestMessageID: store.newestServerMessageID(for: snapshot),
            isKeyWindow: isKeyWindow,
            isAtBottom: isAtBottom,
            validateOwner: validateOwner
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
            writable: store.controlAvailable && (validateOwner?() ?? true),
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
            openDocuments: { if let openDocuments { openDocuments() } else { session.showInspector(.documents) } }
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
                Task {
                    guard validateOwner?() ?? true else { return }
                    await store.rateFeedback(rating, messageID: message.id, expectedContext: context)
                }
            },
            edit: { openFeedbackEditor(for: message, expectedContext: context) },
            remove: {
                Task {
                    guard validateOwner?() ?? true else { return }
                    await store.saveFeedback(FirstMateFeedbackDraft(rating: nil), messageID: message.id, expectedContext: context)
                }
            },
            retry: {
                // A failed thumbs-up or Remove keeps its attempted draft, so
                // retry resubmits that exact payload and request identity.
                let draft = store.feedbackDraft(for: message.featureID, messageID: message.id)
                Task {
                    guard validateOwner?() ?? true else { return }
                    await store.saveFeedback(draft, messageID: message.id, expectedContext: context)
                }
            },
            resolveConflict: {
                Task {
                    guard validateOwner?() ?? true,
                          await store.resolveFeedbackConflict(messageID: message.id, expectedContext: context),
                          validateOwner?() ?? true else { return }
                    let draft = store.feedbackDraft(for: message.featureID, messageID: message.id)
                    await store.saveFeedback(draft, messageID: message.id, expectedContext: context)
                }
            }
        )
    }

    private func openFeedbackEditor(for message: FirstMateMessage, expectedContext: FirstMateStore.OperationContext) {
        let currentContext = store.operationContext
        guard validateOwner?() ?? true, expectedContext == currentContext,
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
