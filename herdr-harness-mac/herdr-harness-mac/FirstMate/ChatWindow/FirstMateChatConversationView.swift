import SwiftUI

/// The chat column under the header: the transcript (or My First Mate's
/// briefing) and the composer.
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

    private var leadColumn: some View {
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
                picks: picksBinding(id.machineID + "|" + id.featureID)
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
    @Binding var picks: [FirstMateMentionCandidate]

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
                    FirstMateChatComposer(
                        mode: .feature(id),
                        session: session,
                        model: model,
                        store: store,
                        draft: draftBinding,
                        attachments: attachmentBinding,
                        picks: $picks,
                        placeholder: "Message \(conversation?.title ?? snapshot.feature.title)",
                        suggestions: FirstMateTranscriptLayout.suggestedReplies(messages: messages, needsYou: needsYou, isTyping: typing),
                        features: FirstMateMentionOption.taggableFeatures(session.conversations, machineID: id.machineID),
                        crew: snapshot.assignments,
                        crewTitle: conversation?.title ?? snapshot.feature.title,
                        canSend: store.selectedFeatureID == id.featureID
                    )
                    .id(id)
                }
            }
        }
    }

    private var draftBinding: Binding<String> {
        let context = store.operationContext
        return Binding(
            get: { store.composerDraft(for: context) },
            set: { store.setComposerDraft($0, for: context) }
        )
    }

    private var attachmentBinding: Binding<[TerminalAttachment]> {
        let featureID = id.featureID
        return Binding(
            get: { store.composerDrafts.attachments(for: featureID) },
            set: { store.composerDrafts.setAttachments($0, for: featureID) }
        )
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
