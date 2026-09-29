import SwiftUI

struct PiChatView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: PiConversationStore
    let paneID: String
    let interactionResponseAvailable: Bool
    let composerPane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int
    let interactionResponder: PiInteractionResponder
    let modelFavorites: ModelFavoritesStore
    var quotes: Binding<[ChatQuote]> = .constant([])
    /// The pane's brief state, so its toggle can sit in the window title bar.
    /// Nil keeps the brief's own strip (standalone hosts and render tests).
    var briefPresentation: ResponseBriefPresentation? = nil
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var responseAudioPlayer = ResponseAudioPlayer()

    var body: some View {
        let briefSource = responseBriefSource
        ResponseBriefChatLayout(
            coordinator: model.responseBriefs,
            transport: model.responseBriefTransport(),
            chat: responseBriefChat,
            latestSource: briefSource,
            presentation: briefPresentation
        ) {
            VStack(spacing: 0) {
            PiConnectionBanner(
                connection: store.connection,
                message: store.lastError,
                transport: store.transport
            )

            if store.isStartingNewSession {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting a new Pi chat — keeping this conversation in history…")
                        .herdrFont(size: HerdrTheme.TextSize.small)
                }
                .foregroundStyle(HerdrTheme.secondaryText)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("pi-new-session-progress")
            }
            if let error = store.newSessionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.alert)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }

            PiChatTimelineView(
                store: store,
                isConnected: store.canSendCommands
                    && interactionResponseAvailable,
                resultArtifacts: paneArtifacts,
                artifactModel: model,
                artifactMachineID: composerPane.machineID
            ) { interaction, response in
                await interactionResponder.respond(
                    to: interaction,
                    response: response,
                    store: store,
                    model: model,
                    pane: composerPane
                )
            }
            .id(paneID)
            .paneResponseLinks(model: model, sourceMachineID: composerPane.machineID)
            .environment(\.saveChatQuote, attachQuote)
            .environment(\.chatQuoteSource, "Pi session \(store.sessionID ?? "unknown")")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = store.commandNotice {
                Text(notice)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.signal)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        store.clearCommandNotice()
                    }
            }

            PromptComposerView(
                model: model,
                pane: composerPane,
                workspace: workspace,
                draft: $draft,
                attachments: $attachments,
                focusRequest: focusRequest,
                piConfiguration: composerConfiguration,
                responseAudioPlayer: responseAudioPlayer,
                activateResponseAudio: activateResponseAudio,
                modelFavorites: modelFavorites,
                quotes: quotes
            )
            .equatable()
            .id(paneID)
            // MonoCode's dock: the composer sits in the pane, centered on the
            // transcript column, with no band or rule of its own.
            .frame(maxWidth: HerdrTheme.transcriptWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        // MonoCode's Haze: one static dusk band behind the top of the chat.
        .background(alignment: .top) { HerdrHazeBand() }
        .herdrPaneBackground()
        // Read acknowledgement belongs to explicit session navigation and
        // interaction in PaneSessionView. A mounted chat, incoming document,
        // or completed response alone does not mean the user has read it.
        .onChange(of: store.phase) { _, newPhase in
            if newPhase == .failed {
                hapticPulse.fire(.failed)
            }
            responseAudioPlayer.responseDidChange(
                hasResponse: newPhase != .working
                    && store.latestCompletedAssistantResponse != nil
            )
        }
        .onChange(of: store.latestCompletedAssistantResponse) { _, response in
            responseAudioPlayer.responseDidChange(
                hasResponse: store.phase != .working && response != nil
            )
        }
        .task(id: paneID) {
            responseAudioPlayer.responseDidChange(
                hasResponse: store.phase != .working
                    && store.latestCompletedAssistantResponse != nil
            )
            await responseAudioPlayer.loadCapabilities {
                try await model.fetchResponseAudioCapabilities(for: composerPane)
            }
        }
        .onDisappear {
            responseAudioPlayer.stop()
        }
            .herdrHaptic(trigger: hapticPulse)
            .accessibilityIdentifier("pi-chat-view")
        }
        .paneResponseLinks(model: model, sourceMachineID: composerPane.machineID)
        .task(id: briefSource?.id) {
            await model.observeResponseBrief(store: store, pane: composerPane)
        }
    }

    private var responseBriefChat: ResponseBriefChatIdentity? {
        guard let sessionID = store.sessionID else { return nil }
        return ResponseBriefChatIdentity(
            machineID: composerPane.machineID,
            paneID: composerPane.paneID,
            sessionID: sessionID
        )
    }

    private var responseBriefSource: ResponseBriefSource? {
        guard let sessionID = store.sessionID else { return nil }
        return ResponseBriefSource.latest(
            turns: store.turns,
            machineID: composerPane.machineID,
            paneID: composerPane.paneID,
            sessionID: sessionID
        )
    }

    private func attachQuote(_ quote: ChatQuote) async throws {
        quotes.wrappedValue.append(quote)
    }

    private var paneArtifacts: [AgentResultArtifact] {
        PaneResultArtifacts.matching(model.resultArtifacts, pane: composerPane, sessionID: store.sessionID)
    }

    private var composerConfiguration: PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: composerPane.piSemantic?.capabilities ?? .unavailable,
            phase: store.phase,
            compactionActivity: store.compactionActivity,
            compactionCompletion: store.compactionCompletion,
            isConnected: store.canSendCommands,
            isSubmitting: store.isSubmitting,
            isAborting: store.isAborting,
            currentModel: store.currentModel,
            availableModels: store.availableModels,
            isLoadingModels: store.isLoadingModels,
            isSettingModel: store.isSettingModel,
            modelCatalogError: store.modelCatalogError,
            isModelSwitchingUnsupported: store.isModelSwitchingUnsupported,
            submit: { text, disposition in
                await store.submit(
                    text: text,
                    disposition: disposition,
                    model: model,
                    pane: composerPane
                )
            },
            abort: {
                await store.abort(model: model, pane: composerPane)
            },
            selectModel: { candidate in
                let succeeded = await store.setModel(candidate, model: model, pane: composerPane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            },
            retryLoadModels: {
                await store.retryLoadModels(model: model, pane: composerPane)
            },
            thinkingLevel: store.thinkingLevel,
            isSettingThinkingLevel: store.isSettingThinkingLevel,
            selectThinkingLevel: { level in
                let succeeded = await store.setThinkingLevel(level, model: model, pane: composerPane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            },
            contextUsage: store.contextUsage,
            sessionCost: store.sessionCost
        )
    }

    private func activateResponseAudio(_ action: ResponseAudioAction) {
        guard let response = store.latestCompletedAssistantResponse else { return }
        responseAudioPlayer.activate(
            action,
            text: response,
            prepare: { action, text in
                try await model.prepareResponseAudio(
                    action: action,
                    text: text,
                    for: composerPane
                )
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, for: composerPane)
            },
            failure: { message in
                model.errorMessage = message
            }
        )
    }
}

extension PiChatView: Equatable {
    static func == (lhs: PiChatView, rhs: PiChatView) -> Bool {
        lhs.model === rhs.model
            && lhs.store === rhs.store
            && lhs.paneID == rhs.paneID
            && lhs.interactionResponseAvailable == rhs.interactionResponseAvailable
            && lhs.composerPane.isEqualIgnoringRevision(to: rhs.composerPane)
            && lhs.workspace.isEqualIgnoringPaneRevisions(to: rhs.workspace)
            && lhs.draft == rhs.draft
            && lhs.attachments == rhs.attachments
            && lhs.quotes.wrappedValue == rhs.quotes.wrappedValue
            && lhs.focusRequest == rhs.focusRequest
            && lhs.interactionResponder === rhs.interactionResponder
            && lhs.modelFavorites === rhs.modelFavorites
            && lhs.briefPresentation === rhs.briefPresentation
    }
}
