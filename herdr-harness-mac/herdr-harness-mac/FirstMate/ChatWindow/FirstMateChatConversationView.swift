import SwiftUI

/// The chat column under the header: the transcript and the shared prompt
/// composer, for a feature or for My First Mate (the lead First Mate). Against
/// companions without a lead, My First Mate keeps its briefing and starts
/// features.
struct FirstMateChatConversationView: View {
    let session: FirstMateChatWindowSession
    let model: HerdrAppModel
    let modelFavorites: ModelFavoritesStore

    /// My First Mate's composer text. Features keep theirs in the window's
    /// store (per feature, per window; never shared with the main window).
    @State private var leadDraft = ""
    /// `@` picks per draft, so switching chats keeps each draft's tags.
    @State private var picks: [String: [FirstMateMentionCandidate]] = [:]

    init(session: FirstMateChatWindowSession, model: HerdrAppModel, modelFavorites: ModelFavoritesStore) {
        self.session = session
        self.model = model
        self.modelFavorites = modelFavorites
    }

    static let contentWidth = FirstMateChatTranscript.maxContentWidth
    static let gutter = FirstMateChatTranscript.gutter

    var body: some View {
        Group {
            switch session.selection {
            case .lead:
                leadColumn
            case .feature(let id):
                featureColumn(id)
            }
        }
        .environment(\.chatProsePalette, .firstMate(FirstMatePalette(scheme: .dark)))
    }

    // MARK: My First Mate

    @ViewBuilder
    private var leadColumn: some View {
        if let machineID = session.leadMachineID {
            if let store = session.leadStore, let snapshot = store.leadSnapshot {
                FirstMateLeadChat(
                    session: session,
                    model: model,
                    store: store,
                    snapshot: snapshot,
                    machineID: machineID,
                    modelFavorites: modelFavorites
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(session.leadStore?.error ?? "Opening First Mate…")
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            briefingColumn
        }
    }

    /// Phase 1, for companions without a lead: a briefing built on this Mac,
    /// and a composer that starts a new feature.
    private var briefingColumn: some View {
        let conversations = session.conversations
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FirstMateDayPill(label: "Today")
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    FirstMateLeadSummaryCard(conversations: conversations, now: .now) { conversation in
                        session.select(.feature(conversation.id), focusComposer: true)
                    }
                    .padding(.top, 6)
                    Text("Describe a new feature below, and First Mate starts it for you.")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                }
                .padding(.top, 22)
                .padding(.bottom, 16)
                .padding(.horizontal, Self.gutter)
                .frame(maxWidth: Self.contentWidth + Self.gutter * 2)
                .frame(maxWidth: .infinity)
            }
            Self.composerZone {
                FirstMateChatComposer(
                    mode: .lead,
                    session: session,
                    model: model,
                    store: nil,
                    draft: $leadDraft,
                    attachments: .constant([]),
                    picks: picksBinding("lead"),
                    placeholder: "Describe a new feature",
                    suggestions: [],
                    // A new feature starts on the first machine that can
                    // create one, so only its features can be tagged.
                    features: FirstMateMentionOption.taggableFeatures(conversations, machineID: session.createMachineIDs.first),
                    crew: [],
                    crewTitle: nil
                )
            }
        }
    }

    // MARK: A feature

    @ViewBuilder
    private func featureColumn(_ id: FirstMateFleetFeatureID) -> some View {
        if let store = session.store(for: id.machineID), let snapshot = store.snapshots[id.featureID] {
            FirstMateFeatureChat(
                session: session,
                model: model,
                store: store,
                snapshot: snapshot,
                id: id,
                modelFavorites: modelFavorites
            )
            .environment(\.firstMateMentionCatalog, FirstMateMentionCatalog(
                conversations: session.conversations.filter { $0.machineID == id.machineID },
                snapshot: snapshot
            ))
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(session.store(for: id.machineID)?.error ?? "Loading the conversation…")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func picksBinding(_ key: String) -> Binding<[FirstMateMentionCandidate]> {
        Binding(get: { picks[key] ?? [] }, set: { picks[key] = $0.isEmpty ? nil : $0 })
    }

    /// The composer's band: the transcript's centered column and gutter.
    static func composerZone(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.top, 4)
            .padding(.bottom, 12)
            .padding(.horizontal, gutter)
            .frame(maxWidth: contentWidth + gutter * 2)
            .frame(maxWidth: .infinity)
    }
}

/// A feature's transcript and composer.
private struct FirstMateFeatureChat: View {
    let session: FirstMateChatWindowSession
    let model: HerdrAppModel
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let id: FirstMateFleetFeatureID
    let modelFavorites: ModelFavoritesStore

    @State private var focusRequest = 0

    private var messages: [FirstMateMessage] { snapshot.messages.filter(\.isConversation) }
    private var conversation: FirstMateConversation? { session.conversations.first { $0.id == id } }
    private var isClosed: Bool { ["completed", "cancelled"].contains(snapshot.feature.status) }

    private var isTyping: Bool {
        FirstMateTranscriptLayout.isTyping(
            messages: messages,
            isSending: store.isSending && store.selectedFeatureID == id.featureID,
            isWorkingOnReply: conversation?.isWorkingOnReply ?? false
        )
    }

    private var needsYou: Bool {
        conversation?.hudStatus.needsYou ?? FirstMateHudStatus.fallback(featureStatus: snapshot.feature.status).needsYou
    }

    var body: some View {
        let typing = isTyping
        VStack(spacing: 0) {
            FirstMateChatTranscript(session: session, store: store, snapshot: snapshot, conversationID: id, isTyping: typing)
                .id(id)
                .contextMenu {
                    Button("Archive feature…", systemImage: "archivebox") { session.requestArchive(id) }
                }
            FirstMateExecutionStateNotice(snapshot: snapshot, health: store.runtimeHealth)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.warning)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FirstMateChatConversationView.gutter + 12)
                    .padding(.bottom, 4)
            }
            if isClosed {
                Label("This feature is closed. Its conversation and evidence remain available.", systemImage: "archivebox")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                FirstMateChatConversationView.composerZone {
                    VStack(alignment: .leading, spacing: 0) {
                        FirstMateSuggestionRow(
                            suggestions: FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: needsYou, isTyping: typing),
                            store: store,
                            featureID: id.featureID
                        ) { session.didMutate(machineID: id.machineID) }
                        FirstMatePromptComposer(
                            store: store,
                            model: model,
                            snapshot: snapshot,
                            canControl: store.controlAvailable && store.selectedFeatureID == id.featureID,
                            modelFavorites: modelFavorites,
                            placeholder: "Message \(conversation?.title ?? snapshot.feature.title)",
                            focusRequest: focusRequest
                        ) { session.didMutate(machineID: id.machineID) }
                    }
                    .id(id)
                }
            }
        }
        .onAppear(perform: takePendingFocus)
        .onChange(of: id) { takePendingFocus() }
    }

    /// A pointer choice (row click, capsule, open request) focuses the composer.
    private func takePendingFocus() {
        guard session.pendingComposerFocus else { return }
        session.pendingComposerFocus = false
        focusRequest &+= 1
    }
}

/// My First Mate as the lead First Mate: one real, continuing conversation
/// across this machine's features, with the same prompt composer as every
/// other chat (attachments, paste, voice, the model pill, and context).
private struct FirstMateLeadChat: View {
    let session: FirstMateChatWindowSession
    let model: HerdrAppModel
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    let machineID: String
    let modelFavorites: ModelFavoritesStore

    @State private var focusRequest = 0

    private var messages: [FirstMateMessage] { snapshot.messages.filter(\.isConversation) }
    private var id: FirstMateFleetFeatureID { FirstMateFleetFeatureID(machineID: machineID, featureID: snapshot.feature.id) }

    /// From the snapshot, which refreshes every 2 s here, rather than the
    /// fleet poll, so the typing bubble ends with the reply.
    private var isTyping: Bool {
        FirstMateTranscriptLayout.isTyping(
            messages: messages,
            isSending: store.isSending && store.selectedFeatureID == snapshot.feature.id,
            isWorkingOnReply: snapshot.feature.coordinatorOwner != nil
        )
    }

    var body: some View {
        let typing = isTyping
        VStack(spacing: 0) {
            if messages.isEmpty, !typing {
                welcome
            } else {
                FirstMateChatTranscript(session: session, store: store, snapshot: snapshot, conversationID: id, isTyping: typing)
                    .id(id)
            }
            FirstMateExecutionStateNotice(snapshot: snapshot, health: store.runtimeHealth)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.warning)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FirstMateChatConversationView.gutter + 12)
                    .padding(.bottom, 4)
            }
            FirstMateChatConversationView.composerZone {
                FirstMatePromptComposer(
                    store: store,
                    model: model,
                    snapshot: snapshot,
                    canControl: store.controlAvailable && store.selectedFeatureID == snapshot.feature.id,
                    modelFavorites: modelFavorites,
                    focusRequest: focusRequest
                ) { session.didMutate(machineID: machineID) }
                .id(id)
            }
        }
        .onAppear {
            guard session.pendingComposerFocus else { return }
            session.pendingComposerFocus = false
            focusRequest &+= 1
        }
    }

    /// An empty lead: the briefing of this machine's features and what to ask.
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FirstMateLeadSummaryCard(
                    conversations: session.conversations.filter { $0.machineID == machineID },
                    now: .now
                ) { conversation in
                    session.select(.feature(conversation.id), focusComposer: true)
                }
                .padding(.top, 6)
                Text("Ask First Mate about any feature, or tell it a decision to pass on.")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            .padding(.top, 22)
            .padding(.bottom, 16)
            .padding(.horizontal, FirstMateChatConversationView.gutter)
            .frame(maxWidth: FirstMateChatConversationView.contentWidth + FirstMateChatConversationView.gutter * 2)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Suggested replies above a feature's composer: the newest message's skim
/// `reply` choices. Tapping one sends it.
private struct FirstMateSuggestionRow: View {
    let suggestions: [String]
    @Bindable var store: FirstMateStore
    let featureID: String
    let didSend: @MainActor () -> Void

    var body: some View {
        if !suggestions.isEmpty {
            FirstMateFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    FirstMateSuggestionChip(title: suggestion) { send(suggestion) }
                }
            }
            .padding(.leading, 2)
            .padding(.bottom, 8)
        }
    }

    private func send(_ text: String) {
        let context = store.operationContext
        guard context.matchesFeature(featureID), !store.isSending else { return }
        Task {
            if await store.sendPreparedMessage(text, expectedContext: context) { didSend() }
        }
    }
}

/// My First Mate's briefing, built on this Mac from the fleet summary. It is
/// labeled as a summary: no agent wrote it.
struct FirstMateLeadSummaryCard: View {
    let conversations: [FirstMateConversation]
    let now: Date
    let open: (FirstMateConversation) -> Void

    var body: some View {
        let briefing = FirstMateLeadBriefing.build(conversations: conversations, now: now, calendar: .current)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "list.bullet.rectangle")
                    .herdrFont(size: 12, weight: .medium)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(HerdrTheme.accent.opacity(0.13), in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Summary")
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                        .foregroundStyle(HerdrTheme.accent)
                    Text("Built from your features. Not a message from an agent.")
                        .herdrFont(size: 10.5)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
                Spacer(minLength: 8)
                Text("Updated \(FirstMateChatTime.clock(for: now, calendar: .current))")
                    .herdrFont(size: HerdrTheme.TextSize.micro)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .monospacedDigit()
            }
            FirstMateBriefingFlow(segments: briefing.segments, open: open)
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.inkFill(0.06), in: .rect(cornerRadius: HerdrTheme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: HerdrTheme.Radius.card).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary of your features: \(briefing.plainText)")
    }
}
