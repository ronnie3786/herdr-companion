import SwiftUI

struct FirstMateChatView: View {
    @Bindable var store: FirstMateStore
    @Bindable var model: HerdrAppModel
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    let modelFavorites: ModelFavoritesStore

    @Environment(\.colorScheme) private var scheme
    @State private var followsLatest = true
    @State private var feedbackEditor: FirstMateFeedbackEditorTarget?

    private var featureIsClosed: Bool {
        ["completed", "cancelled"].contains(snapshot.feature.status)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .textSelection(.enabled)
            }

            transcript
            featureStatus
            feedbackNotices

            if featureIsClosed {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    FirstMateCoordinatorContextView(
                        feature: snapshot.feature,
                        capabilityAvailable: store.contextSupported
                    )
                    if !store.attachmentsSupported {
                        Label("Update this feature's companion server to attach files.", systemImage: "arrow.down.circle")
                            .herdrFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    FirstMateComposerModelControls(
                        store: store,
                        feature: featureWithCurrentSessionSelection,
                        context: store.operationContext,
                        canControl: canControl,
                        hasQueuedWork: snapshot.messages.contains { $0.status == "queued" },
                        modelFavorites: modelFavorites
                    )
                    PromptComposerView(
                        model: model,
                        destination: composerDestination,
                        draft: draftBinding,
                        attachments: attachmentBinding,
                        quotes: quoteBinding,
                        containsDictation: dictationBinding,
                        modelFavorites: modelFavorites
                    )
                    .equatable()
                    .padding(8)
                    .background(HerdrTheme.graphite, in: .rect(cornerRadius: 10))
                    .environment(\.colorScheme, .dark)
                    .id(composerDestination.id)
                }
                .padding(16)
                .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(FirstMatePalette(scheme: scheme).line)
                }
                .padding(16)
            }
        }
        .background(FirstMatePalette(scheme: scheme).background)
        .task(id: feedbackLoadID) { await loadFeedback() }
        .onChange(of: store.operationContext) { _, _ in feedbackEditor = nil }
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
            unsupported: store.unsupported,
            supported: store.feedbackSupported
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
            .herdrFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        // A response rated helpful (or unrated) starts a fresh negative draft;
        // an existing negative rating keeps its saved reasons and note.
        if store.feedback(for: message.featureID, messageID: message.id)?.rating != .down {
            store.setFeedbackDraft(
                FirstMateFeedbackDraft(rating: .down),
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("First Mate").herdrFont(.title2, weight: .semibold)
                Text(snapshot.feature.title)
                    .herdrFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Pause feature", systemImage: "pause") {
                    let context = store.operationContext
                    Task { await store.perform("pause", expectedContext: context) }
                }
                Button("Resume feature", systemImage: "play") {
                    let context = store.operationContext
                    Task { await store.perform("resume", expectedContext: context) }
                }
            } label: {
                FirstMateStatusLabel(status: snapshot.feature.status)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canControl || store.isSending || featureIsClosed)
        }
        .padding(22)
    }

    private var transcript: some View {
        let eligibleQuoteIDs = FirstMateQuoteEligibility.messageIDs(in: snapshot.messages)
        let quoteContext = store.operationContext
        let feedbackContext = store.operationContext
        let feedbackSupported = store.feedbackSupported
        let feedbackWritable = store.controlAvailable
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }) { message in
                        let feedback = FirstMateResponseFeedbackPresentation.make(
                            message: message,
                            supported: feedbackSupported,
                            writable: feedbackWritable,
                            isSaving: store.isSavingFeedback(featureID: message.featureID, messageID: message.id),
                            record: store.feedback(for: message.featureID, messageID: message.id)
                        )
                        FirstMateMessageView(
                            message: message,
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
                            }
                        )
                    }
                    Color.clear.frame(height: 1).id("first-mate-chat-end")
                }
                .padding(22)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                followsLatest = nearBottom
            }
            .onChange(of: snapshot.messages.last?.id) { _, _ in
                if followsLatest { proxy.scrollTo("first-mate-chat-end", anchor: .bottom) }
            }
            .onChange(of: snapshot.feature.id) { followsLatest = true }
            .id(snapshot.feature.id)
        }
    }

    @ViewBuilder
    private var featureStatus: some View {
        if featureIsClosed {
            Label("This feature is closed. Its conversation and evidence remain available.", systemImage: "archivebox")
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        } else if snapshot.feature.status == "awaiting_direction" {
            Label(
                snapshot.currentVisit?.status == "completed"
                    ? "Stage complete. Waiting for your direction."
                    : "Waiting for your direction before work continues.",
                systemImage: "hand.raised"
            )
            .herdrFont(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.05))
        } else if ["running", "coordinating", "recovering"].contains(snapshot.feature.status) {
            Label("Work continues in the background. You can talk here.", systemImage: "waveform.path")
                .herdrFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }

    private var featureWithCurrentSessionSelection: FirstMateFeature {
        var feature = snapshot.feature
        if let nativeSessionID = feature.nativeSessionID,
           let session = snapshot.coordinatorSessions.last(where: { $0.nativeSessionID == nativeSessionID }),
           let selection = session.modelSelection {
            feature.modelSelection = selection
        }
        return feature
    }

    private var draftBinding: Binding<String> {
        let context = store.operationContext
        return Binding(
            get: { store.composerDraft(for: context) },
            set: { store.setComposerDraft($0, for: context) }
        )
    }

    private var attachmentBinding: Binding<[TerminalAttachment]> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.attachments(for: featureID) },
            set: { store.composerDrafts.setAttachments($0, for: featureID) }
        )
    }

    private var quoteBinding: Binding<[ChatQuote]> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.quotes(for: featureID) },
            set: { store.composerDrafts.setQuotes($0, for: featureID) }
        )
    }

    private var dictationBinding: Binding<Bool> {
        let featureID = snapshot.feature.id
        return Binding(
            get: { store.composerDrafts.containsDictation(for: featureID) },
            set: { store.composerDrafts.setContainsDictation($0, for: featureID) }
        )
    }

    private var composerDestination: PromptComposerDestination {
        let context = store.operationContext
        let featureID = snapshot.feature.id
        return PromptComposerDestination(
            id: context.destinationID(for: featureID)
                ?? "first-mate:invalid:\(context.lifecycleIdentity.opaqueID)",
            canControl: canControl && !featureIsClosed,
            isSubmitting: store.isSending,
            isBusy: false,
            placeholder: "Give direction, ask a question, or change the plan…",
            sendAccessibilityLabel: "Send",
            sendAccessibilityHint: "Sends direction to this First Mate feature",
            supportsAttachments: store.attachmentsSupported,
            supportsVoice: true,
            supportsPaneTools: false,
            isCurrent: {
                context == store.operationContext && store.selectedFeatureID == featureID
            },
            acceptsCompletion: {
                store.isDestinationAlive(context)
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
                await store.sendPreparedMessage(message, expectedContext: context)
            },
            reportError: { store.reportComposerError($0) },
            reportToast: { model.toastMessage = $0 }
        )
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
