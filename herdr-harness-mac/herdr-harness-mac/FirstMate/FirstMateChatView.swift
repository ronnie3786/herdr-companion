import SwiftUI

struct FirstMateChatView: View {
    @Bindable var store: FirstMateStore
    @Bindable var model: HerdrAppModel
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    let modelFavorites: ModelFavoritesStore

    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.firstMateMarkRead) private var markRead
    @State private var followsLatest = true
    @State private var feedbackEditor: FirstMateFeedbackEditorTarget?
    /// Skim or Full reply per message, kept while this chat is open.
    @State private var skimState = SkimDisplayState()

    private var featureIsClosed: Bool {
        ["completed", "cancelled"].contains(snapshot.feature.status)
    }

    /// The newest First Mate message, whether the person can see it (the
    /// chat is in the key window and scrolled to the bottom), and whether the
    /// fleet reports the chat unread, so a fleet that catches up after the
    /// transcript marks it again.
    private var readMarker: FirstMateChatReadMarker {
        FirstMateChatReadMarker(
            featureID: snapshot.feature.id,
            messageID: snapshot.messages.last { $0.role == "assistant" && $0.isConversation }?.id,
            isVisible: controlActiveState == .key && followsLatest,
            fleetUnreadThrough: markRead?.unreadThrough[snapshot.feature.id]
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.warning)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrHairline(.bottom)
                    .textSelection(.enabled)
            }

            transcript
            featureStatus
            feedbackNotices

            if !featureIsClosed {
                // The shared composer, in either appearance: the coordinator
                // context line on top, the model pill in its tool row.
                FirstMatePromptComposer(
                    store: store,
                    model: model,
                    snapshot: snapshot,
                    canControl: canControl,
                    modelFavorites: modelFavorites
                )
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .herdrPaneBackground(FirstMatePalette(scheme: scheme).background)
        .task(id: feedbackLoadID) { await loadFeedback() }
        .onChange(of: store.operationContext) { _, _ in feedbackEditor = nil }
        .onChange(of: readMarker, initial: true) { _, marker in
            guard let messageID = marker.markTarget else { return }
            markRead?(featureID: marker.featureID, messageID: messageID)
        }
        .sheet(item: $feedbackEditor) { target in
            FirstMateFeedbackEditor(store: store, target: target)
        }
    }

    private var feedbackLoadID: String {
        "\(snapshot.feature.id)|\(store.lifecycle.opaqueID)|\(store.feedbackSupported)"
    }

    private var showsFeedbackUpgradeNotice: Bool {
        FirstMateFeedbackSurface.showsUpgradeNotice(
            hasLoaded: store.hasLoaded,
            capability: store.feedbackCapability,
            surfaceUnsupported: store.unsupported
        )
    }

    @ViewBuilder
    private var feedbackNotices: some View {
        let featureID = snapshot.feature.id
        if showsFeedbackUpgradeNotice || store.feedbackError(for: featureID) != nil {
            VStack(alignment: .leading, spacing: 6) {
                if showsFeedbackUpgradeNotice {
                    Label(
                        "Update this feature's companion server to rate First Mate responses.",
                        systemImage: "arrow.down.circle"
                    )
                    .accessibilityIdentifier("first-mate-feedback-upgrade")
                }
                if let error = store.feedbackError(for: featureID) {
                    HStack(spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                        Button("Try again") {
                            let context = store.operationContext
                            Task { await store.loadFeedback(expectedContext: context) }
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("first-mate-feedback-reload")
                    }
                }
            }
            .herdrFont(size: HerdrTheme.TextSize.small)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.top)
        }
    }

    private func loadFeedback() async {
        guard store.feedbackSupported else { return }
        let context = store.operationContext
        await store.loadFeedback(expectedContext: context)
        guard store.feedbackSupported else { return }
        await store.loadFeedbackCategories(expectedContext: context)
    }

    private func openFeedbackEditor(
        for message: FirstMateMessage,
        expectedContext: FirstMateStore.OperationContext
    ) {
        let currentContext = store.operationContext
        guard expectedContext == currentContext,
              currentContext.matchesFeature(message.featureID),
              FirstMateFeedbackEligibility.isEligible(message),
              store.feedbackSupported else { return }
        // A response rated helpful starts a fresh negative draft pinned to
        // the loaded record's revision; an existing negative rating keeps its
        // saved reasons and note. Before the first record load completes no
        // draft is seeded from the empty cache.
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

    private var transcript: some View {
        let entries = snapshot.conversationEntries
        let eligibleQuoteIDs = FirstMateQuoteEligibility.messageIDs(in: snapshot.messages)
        let pendingDecisionID = snapshot.pendingDecisionMessageID
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        messageRow(entry.message, eligibleQuoteIDs: eligibleQuoteIDs, pendingDecisionID: pendingDecisionID)
                        if !entry.additionalReplies.isEmpty {
                            DisclosureGroup("Additional response from this turn") {
                                ForEach(entry.additionalReplies) { message in
                                    messageRow(message, eligibleQuoteIDs: eligibleQuoteIDs, pendingDecisionID: pendingDecisionID)
                                }
                            }
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .accessibilityIdentifier("first-mate-additional-replies-\(entry.id)")
                        }
                    }
                    Color.clear.frame(height: 1).id("first-mate-chat-end")
                }
                .environment(\.skimDisplayState, skimState)
                .environment(\.skimScrollTo) { id in
                    withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
                }
                // Rows carry their own 16pt gutters.
                .padding(.top, 6)
                .frame(maxWidth: HerdrTheme.transcriptWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                followsLatest = nearBottom
            }
            .onChange(of: entries.last?.id) { _, _ in
                if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
            }
            .onChange(of: snapshot.feature.id) { followsLatest = true }
            .id(snapshot.feature.id)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: FirstMateMessage, eligibleQuoteIDs: Set<String>, pendingDecisionID: String?) -> some View {
        let quoteContext = store.operationContext
        let feedbackContext = store.operationContext
        let feedbackSupported = store.feedbackSupported
        let feedbackWritable = store.controlAvailable
        let feedback = FirstMateResponseFeedbackPresentation.make(
            message: message,
            supported: feedbackSupported,
            writable: feedbackWritable,
            isSaving: store.isSavingFeedback(featureID: message.featureID, messageID: message.id),
            record: store.feedback(for: message.featureID, messageID: message.id),
            saveErrorMessage: store.feedbackSaveError(featureID: message.featureID, messageID: message.id),
            hasConflict: store.feedbackConflict(featureID: message.featureID, messageID: message.id),
            isFeedbackLoaded: store.hasLoadedFeedback(for: message.featureID)
        )
        FirstMateMessageView(
            message: message,
            isPendingDecision: pendingDecisionID == message.id,
            canQuote: canControl && !featureIsClosed && eligibleQuoteIDs.contains(message.id),
            quoteSource: "First Mate feature \(snapshot.feature.id) · message \(message.id)",
            saveQuote: { quote in
                try await saveQuote(
                    quote,
                    sourceMessageID: message.id,
                    expectedContext: quoteContext
                )
            },
            feedback: feedback,
            rateFeedback: { rating in
                Task {
                    await store.rateFeedback(
                        rating,
                        messageID: message.id,
                        expectedContext: feedbackContext
                    )
                }
            },
            editFeedback: {
                openFeedbackEditor(for: message, expectedContext: feedbackContext)
            },
            removeFeedback: {
                Task {
                    await store.saveFeedback(
                        FirstMateFeedbackDraft(rating: nil),
                        messageID: message.id,
                        expectedContext: feedbackContext
                    )
                }
            },
            retryFeedback: {
                // A failed thumbs-up or Remove rating keeps its
                // attempted draft in the store, so retry resubmits
                // that exact payload and reuses its request identity.
                let draft = store.feedbackDraft(
                    for: message.featureID,
                    messageID: message.id
                )
                Task {
                    await store.saveFeedback(
                        draft,
                        messageID: message.id,
                        expectedContext: feedbackContext
                    )
                }
            },
            resolveFeedbackConflict: {
                // A stale revision is recovered only through this
                // explicit action: reload the latest record,
                // rebase the preserved up/clear payload, then
                // retry with the new revision and request ID.
                Task {
                    guard await store.resolveFeedbackConflict(
                        messageID: message.id,
                        expectedContext: feedbackContext
                    ) else { return }
                    let draft = store.feedbackDraft(
                        for: message.featureID,
                        messageID: message.id
                    )
                    await store.saveFeedback(
                        draft,
                        messageID: message.id,
                        expectedContext: feedbackContext
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var featureStatus: some View {
        if featureIsClosed {
            FirstMateChatNote(
                text: "This feature is closed. Its conversation and evidence remain available.",
                systemImage: "archivebox"
            )
        } else if let warning = store.runtimeHealth?.warning {
            FirstMateExecutionNotice(text: warning, lastSuccessAt: store.runtimeHealth?.lastSuccessAt)
        } else if store.error != nil {
            FirstMateExecutionNotice(text: "Live execution status is unavailable. Showing the last saved workflow.")
        } else if snapshot.feature.status == "blocked" {
            FirstMateExecutionNotice(text: snapshot.events.last(where: { $0.type == "reliability.blocked" })?.summary ?? "Work is blocked. Review the retained evidence and give First Mate direction.")
        } else if snapshot.recoveryNeedsDirection {
            FirstMateExecutionNotice(text: store.runtimeHealth?.automaticRecovery == true
                ? "Checking retained work for a safe automatic continuation. Uncertain effects or human checkpoints will stop recovery and ask for your direction. See Stability & recovery in Workflow."
                : "Execution was interrupted and needs your direction. Inspect the retained work and latest handoff in Workflow, then ask First Mate to recover the assignment after verifying uncertain effects.")
        } else if snapshot.feature.status == "awaiting_direction" {
            FirstMateChatNote(
                text: snapshot.pendingDecisionMessageID != nil
                    ? "Reply to the decision marked above to continue."
                    : "Waiting for your direction before work continues.",
                systemImage: "hand.raised",
                tone: FirstMateStatusColors.color(for: .awaitingDirection, scheme: scheme)
            )
        } else if ["running", "coordinating"].contains(snapshot.feature.status) {
            FirstMateChatNote(
                text: store.runtimeHealth == nil
                    ? "Last reported as active. This companion does not report execution health."
                    : "Background monitoring is active. You can talk here.",
                systemImage: "waveform.path.ecg"
            )
        }
    }

    private func saveQuote(
        _ quote: ChatQuote,
        sourceMessageID: String,
        expectedContext: FirstMateStore.OperationContext
    ) async throws {
        let currentContext = store.operationContext
        let currentSnapshot = store.snapshot(for: expectedContext)
        guard FirstMateQuoteEligibility.canStage(
            sourceMessageID: sourceMessageID,
            snapshot: currentSnapshot,
            expectedContext: expectedContext,
            currentContext: currentContext,
            canControl: store.controlAvailable
        ), let featureID = currentSnapshot?.feature.id else {
            throw CancellationError()
        }
        var values = store.composerDrafts.quotes(for: featureID)
        values.append(quote)
        store.composerDrafts.setQuotes(values, for: featureID)
    }
}

/// First Mate's shared-composer wiring.
///
/// The destination identity is captured here; the live closures below consult
/// `store` so a completion that resumes after a suspension never trusts the
/// snapshot from the render that created this destination. Internal so the
/// production wiring (including live readiness) can be exercised directly in
/// tests.
@MainActor
extension PromptComposerDestination {
    static func firstMate(
        store: FirstMateStore,
        model: HerdrAppModel,
        snapshot: FirstMateSnapshot,
        canControl: Bool,
        placeholder: String? = nil,
        didSubmit: (@MainActor () -> Void)? = nil
    ) -> PromptComposerDestination {
        let context = store.operationContext
        let featureID = snapshot.feature.id
        let featureIsClosed = ["completed", "cancelled"].contains(snapshot.feature.status)
        let isLead = snapshot.feature.isLead
        return PromptComposerDestination(
            voicePolicy: .firstMateStopToSend,
            id: context.destinationID(for: featureID)
                ?? "first-mate:invalid:\(context.lifecycleIdentity.opaqueID)",
            canControl: canControl && !featureIsClosed,
            isSubmitting: store.isSending,
            isBusy: false,
            placeholder: placeholder ?? (isLead
                ? "Ask First Mate about any feature, or tell it what to pass on…"
                : "Give direction, ask a question, or change the plan…"),
            sendAccessibilityLabel: "Send",
            sendAccessibilityHint: isLead ? "Sends your message to First Mate" : "Sends direction to this First Mate feature",
            supportsAttachments: store.attachmentsSupported,
            supportsVoice: true,
            supportsPaneTools: false,
            isCurrent: {
                context == store.operationContext && store.selectedFeatureID == featureID
            },
            acceptsCompletion: {
                store.isDestinationAlive(context)
            },
            isReadyToSubmit: {
                // Live owner state: neither the view value captured by a
                // suspension nor this destination's snapshot flags receive
                // re-renders while transcription runs.
                store.controlAvailable
                    && !store.isSending
                    && store.isDestinationAlive(context)
                    && !(store.snapshot(for: context).map {
                        ["completed", "cancelled"].contains($0.feature.status)
                    } ?? false)
            },
            upload: { url, contentType in
                if store.isDemo {
                    return UploadedAttachment(
                        id: UUID().uuidString,
                        filename: url.lastPathComponent,
                        originalFilename: url.lastPathComponent,
                        contentType: contentType,
                        size: 0,
                        path: "/tmp/herdr-demo-first-mate/\(url.lastPathComponent)",
                        workspaceID: "first-mate:\(featureID)",
                        createdAt: ISO8601DateFormatter().string(from: .now)
                    )
                }
                return try await store.uploadAttachment(at: url, contentType: contentType, expectedContext: context)
            },
            transcribe: { url in
                if store.isDemo { return try await model.transcribeVoiceNote(at: url) }
                return try await VoiceTranscriptionPipeline.run(
                    preferPrivate: model.preferPrivateTranscription,
                    privateTranscription: {
                        let response = try await store.transcribeVoice(at: url, expectedContext: context)
                        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
                        return VoiceTranscription(
                            text: text,
                            provider: response.backend.lowercased().contains("parakeet") ? .parakeet : .server,
                            language: response.language,
                            usedFallback: false
                        )
                    },
                    appleTranscription: {
                        let text = try await AppleVoiceTranscriber.transcribe(fileURL: url)
                        return VoiceTranscription(
                            text: text,
                            provider: .apple,
                            language: Locale.current.language.languageCode?.identifier,
                            usedFallback: false
                        )
                    }
                )
            },
            submit: { message in
                let sent = await store.sendPreparedMessage(message, expectedContext: context)
                if sent { didSubmit?() }
                return sent
            },
            reportError: { store.reportComposerError($0) },
            reportToast: { model.toastMessage = $0 }
        )
    }
}

/// A one-line note between the transcript and the composer (MonoCode's
/// `.fm-note`): 12pt text under a hairline, tinted only when it asks for you.
private struct FirstMateChatNote: View {
    let text: String
    let systemImage: String
    var tone: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .herdrFont(size: 12)
                .foregroundStyle(tone ?? HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(text)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(tone ?? HerdrTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone?.opacity(0.06) ?? .clear)
        .herdrHairline(.top)
        .accessibilityElement(children: .combine)
    }
}
