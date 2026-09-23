import SwiftUI

struct FirstMateChatView: View {
    @Bindable var store: FirstMateStore
    @Bindable var model: HerdrAppModel
    let snapshot: FirstMateSnapshot
    let canControl: Bool
    let modelFavorites: ModelFavoritesStore

    @Environment(\.colorScheme) private var scheme
    @State private var followsLatest = true

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
                FirstMateStatusLabel(status: store.executionDisplayStatus(for: snapshot.feature))
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }) { message in
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
        } else if ["running", "coordinating"].contains(snapshot.feature.status) {
            Label(store.runtimeHealth == nil ? "Last reported as active. This companion does not report execution health." : "Background monitoring is active. You can talk here.", systemImage: "waveform.path")
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
