import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How the composer's tool row decides its fit.
///
/// The app always uses `.automatic`. `.pinnedWidest` exists for the offscreen
/// render tests: `ViewThatFits` measures every candidate, and a candidate that
/// loses the measurement can still leave its tools in an `NSHostingView`
/// snapshot — a screenshot showing two tool rows for a composer that only ever
/// mounts one.
enum ComposerToolRowFit: Equatable, Sendable {
    case automatic
    case pinnedWidest
}

/// The shared prompt composer, hosted by both the terminal pane and Pi chat.
///
/// Mac notes:
/// - The prompt and labeled Attach, Paste code and Voice actions share one
///   quiet input surface. More opens secondary tools. Model, reasoning and
///   terminal keys sit above the input, with adaptive rows for larger text.
/// - Return sends. Shift/Option/Command+Return all break the line, so a
///   multi-line prompt never depends on remembering which one this app chose.
///   `ComposerReturnKeyRouter` owns that table; `onKeyPress` and `onSubmit`
///   both route through it, because SwiftUI can deliver a ⌘Return to either.
/// - Typing `$` at a token boundary raises `ComposerSkillsHUD` — the workspace's
///   skills, filtered as you type, accepted with Return/Tab. It is an
///   accelerator: it never takes focus, never blocks a send, and any signal
///   that you did not mean a skill (space, escape, no matches) makes it vanish
///   without touching the draft. All of its rules live in
///   `ComposerSkillsPalette`.
/// - Attachments come from one `fileImporter` (the Mac open panel already
///   browses Photos) plus drag-and-drop onto the composer.
struct PromptComposerView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane?
    let workspace: HerdrWorkspace?
    let destination: PromptComposerDestination
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    @Binding var quotes: [ChatQuote]
    let persistedDictation: Binding<Bool>?
    let focusRequest: Int
    let dismissFocusRequest: Int
    let piConfiguration: PiPromptComposerConfiguration?
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?
    let toolRowFit: ComposerToolRowFit
    let modelFavorites: ModelFavoritesStore
    let codePasteboard: NSPasteboard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.herdrFontScale) private var fontScale
    @State private var composerWidth: CGFloat = .infinity
    @State private var editorTarget = ComposerEditorTarget()
    @FocusState private var isFocused: Bool
    @State private var isShowingFileImporter = false
    @State private var isShowingVoiceRecorder = false
    @State private var isShowingFileSearch = false
    @State private var isShowingJira = false
    @State private var isShowingMoreTools = false
    @State private var showsTerminalKeys = false
    @State private var isFileDropTargeted = false
    @State private var isConversationDropTargeted = false
    @State private var disposition: PiPromptDisposition = .prompt
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var isCTACapture = false
    @State private var localDraftContainsDictation = false
    @State private var isLockPulsing = false
    @State private var skillsPalette = ComposerSkillsPalette()
    @State private var didLoadSkills = false
    @State private var isLoadingSkills = false

    init(
        model: HerdrAppModel,
        pane: HerdrPane,
        workspace: HerdrWorkspace,
        draft: Binding<String>,
        attachments: Binding<[TerminalAttachment]>,
        focusRequest: Int,
        dismissFocusRequest: Int = 0,
        piConfiguration: PiPromptComposerConfiguration? = nil,
        responseAudioPlayer: ResponseAudioPlayer? = nil,
        activateResponseAudio: ((ResponseAudioAction) -> Void)? = nil,
        toolRowFit: ComposerToolRowFit = .automatic,
        modelFavorites: ModelFavoritesStore,
        quotes: Binding<[ChatQuote]> = .constant([]),
        codePasteboard: NSPasteboard = .general
    ) {
        let destinationID = "pane:\(pane.id):generation:\(model.connectionGeneration)"
        self.model = model
        self.pane = pane
        self.workspace = workspace
        self.destination = PromptComposerDestination(
            id: destinationID,
            canControl: piConfiguration?.isConnected ?? model.canControl,
            isSubmitting: piConfiguration?.isSubmitting ?? model.isSending,
            isBusy: piConfiguration?.isCompacting ?? false,
            placeholder: piConfiguration?.placeholder(for: piConfiguration?.preferredDisposition ?? .prompt)
                ?? (pane.agentStatus == .unknown ? "run or type into this shell" : "message \(pane.displayAgentName)"),
            sendAccessibilityLabel: piConfiguration?.preferredDisposition.label ?? "Send",
            sendAccessibilityHint: piConfiguration == nil
                ? "Sends the prompt to this terminal"
                : "Sends using \(piConfiguration?.preferredDisposition.label.lowercased() ?? "prompt") mode",
            supportsAttachments: true,
            supportsVoice: true,
            supportsPaneTools: true,
            isCurrent: {
                destinationID == "pane:\(pane.id):generation:\(model.connectionGeneration)"
                    && model.pane(id: pane.id) != nil
            },
            acceptsCompletion: {
                destinationID == "pane:\(pane.id):generation:\(model.connectionGeneration)"
                    && model.pane(id: pane.id) != nil
            },
            upload: { url, contentType in
                try await model.uploadAttachment(from: url, contentType: contentType, to: workspace)
            },
            transcribe: { url in try await model.transcribeVoiceNote(at: url) },
            submit: { message in
                if let piConfiguration {
                    return await piConfiguration.submit(message, piConfiguration.preferredDisposition)
                }
                return await model.sendPrompt(message, to: pane)
            },
            reportError: { model.errorMessage = $0 },
            reportToast: { model.toastMessage = $0 }
        )
        _draft = draft
        _attachments = attachments
        _quotes = quotes
        persistedDictation = nil
        self.focusRequest = focusRequest
        self.dismissFocusRequest = dismissFocusRequest
        self.piConfiguration = piConfiguration
        self.responseAudioPlayer = responseAudioPlayer
        self.activateResponseAudio = activateResponseAudio
        self.toolRowFit = toolRowFit
        self.modelFavorites = modelFavorites
        self.codePasteboard = codePasteboard
        _disposition = State(initialValue: piConfiguration?.preferredDisposition ?? .prompt)
    }

    init(
        model: HerdrAppModel,
        destination: PromptComposerDestination,
        draft: Binding<String>,
        attachments: Binding<[TerminalAttachment]>,
        quotes: Binding<[ChatQuote]>,
        containsDictation: Binding<Bool>? = nil,
        focusRequest: Int = 0,
        dismissFocusRequest: Int = 0,
        modelFavorites: ModelFavoritesStore,
        codePasteboard: NSPasteboard = .general
    ) {
        self.model = model
        pane = nil
        workspace = nil
        self.destination = destination
        _draft = draft
        _attachments = attachments
        _quotes = quotes
        persistedDictation = containsDictation
        self.focusRequest = focusRequest
        self.dismissFocusRequest = dismissFocusRequest
        piConfiguration = nil
        responseAudioPlayer = nil
        activateResponseAudio = nil
        toolRowFit = .automatic
        self.modelFavorites = modelFavorites
        self.codePasteboard = codePasteboard
        _disposition = State(initialValue: .prompt)
    }

    private var stagedConversationReferences: [ConversationContextReference] {
        guard let pane else { return [] }
        return model.conversationReferences(for: pane.id)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty || !quotes.isEmpty || !stagedConversationReferences.isEmpty {
                ComposerAttachmentTray(
                    attachments: attachments,
                    retry: retryAttachment,
                    remove: removeAttachment,
                    quotes: quotes,
                    removeQuote: { id in quotes.removeAll { $0.id == id } },
                    conversationReferences: stagedConversationReferences,
                    removeConversationReference: { id in
                        guard let pane else { return }
                        model.removeConversationReference(id, from: pane.id)
                    }
                )
            }

            if let compaction = piConfiguration?.compactionPresentation {
                PiCompactionStatusBar(presentation: compaction)
                    .transition(semanticControlTransition)
            }

            voiceCaptureStatus

            if showsTerminalKeys {
                composerToolRow
                    .transition(semanticControlTransition)
            }

            composerToolbar

            composerRow
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            composerWidth = width
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: piConfiguration?.phase
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: piConfiguration?.compactionPresentation
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: quickVoiceCapture.phase)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: skillsPalette.isVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsTerminalKeys)
        .overlay(alignment: .topLeading) {
            if skillsPalette.isVisible {
                // Floats above the whole composer instead of pushing it down:
                // the draft must not move under the caret while the HUD is up.
                // Overriding the child's `.top` guide with its own bottom edge
                // is what lifts it clear of the stack.
                ComposerSkillsHUD(
                    matches: skillsPalette.matches,
                    totalCount: skillsPalette.skills.count,
                    highlightedIndex: skillsPalette.highlightedIndex,
                    query: skillsPalette.query,
                    visibleRowCount: skillsPalette.visibleRowCount,
                    select: acceptSkill(at:),
                    highlight: { index in skillsPalette.highlight(index) }
                )
                .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 8 }
                .transition(semanticControlTransition)
            }
        }
        .herdrHaptic(trigger: hapticPulse)
        .onAppear {
            quickVoiceCapture.onLock = {
                hapticPulse.fire(.recordingLocked)
            }
            isLockPulsing = quickVoiceCapture.phase == .locked
        }
        .onDisappear {
            quickVoiceCapture.cancel()
        }
        .onChange(of: destination.id) {
            quickVoiceCapture.cancel()
            skillsPalette.dismiss()
            isShowingMoreTools = false
            showsTerminalKeys = false
            if case .none = persistedDictation { localDraftContainsDictation = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                quickVoiceCapture.cancel()
            }
        }
        .onChange(of: quickVoiceCapture.phase) { _, phase in
            isLockPulsing = phase == .locked
            if phase == .transcribing {
                // Keep the hold gesture mounted until release, then return the
                // key window to the prompt before inserting the transcription.
                isShowingMoreTools = false
            }
            if phase == .idle {
                isCTACapture = false
            }
        }
        .onChange(of: quickVoiceCapture.recorderStatus) { _, status in
            if status == .finished, quickVoiceCapture.phase == .locked {
                finishLockedQuickVoiceCapture()
            }
        }
        .onChange(of: draft) { _, updatedDraft in
            if updatedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setDraftContainsDictation(false)
            }
            updateSkillsPalette()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, let pane {
                model.acknowledgeUnreadAlerts(for: pane)
            } else {
                // Leaving the field is as clear a "not now" as pressing escape.
                skillsPalette.dismiss()
            }
        }
        .onChange(of: focusRequest) {
            if let pane { model.acknowledgeUnreadAlerts(for: pane) }
            isFocused = true
        }
        .onChange(of: dismissFocusRequest) {
            isFocused = false
        }
        .onChange(of: piConfiguration?.availableDispositions) { _, options in
            guard let options, !options.contains(disposition) else { return }
            disposition = options.first ?? .prompt
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                queueAttachments(urls, ownership: .userSelected)
            case let .failure(error):
                destination.reportError(error.localizedDescription)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard destination.supportsAttachments, canControl, destination.isCurrent() else { return false }
            queueAttachments(urls, ownership: .userSelected)
            return true
        } isTargeted: { isTargeted in
            isFileDropTargeted = destination.supportsAttachments && isTargeted
        }
        .dropDestination(for: ConversationContextTransfer.self) { transfers, _ in
            guard destination.supportsPaneTools,
                  canControl, !isSubmitting, !isPiCompacting,
                  let pane, let transfer = transfers.first else { return false }
            Task { await model.addConversationContext(transfer, toDestinationPaneID: pane.id) }
            return true
        } isTargeted: { isTargeted in
            isConversationDropTargeted = destination.supportsPaneTools && isTargeted
        }
        .overlay {
            if isFileDropTargeted || isConversationDropTargeted {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(HerdrTheme.accent, lineWidth: 1.5)
                    .padding(-6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isShowingVoiceRecorder) {
            HerdrVoiceNoteRecorderSheet(
                save: { url in
                    isShowingVoiceRecorder = false
                    guard destination.acceptsCompletion() else {
                        removeTemporarySources([url], ownership: .appTemporary)
                        return
                    }
                    queueAttachments([url], ownership: .appTemporary)
                },
                transcribe: { url in
                    try await destination.transcribe(url)
                },
                insertTranscript: { result in
                    isShowingVoiceRecorder = false
                    guard destination.acceptsCompletion() else { return }
                    appendTranscript(result.text)
                    hapticPulse.fire(.transcriptionSucceeded)
                    destination.reportToast(result.usedFallback
                        ? "Parakeet unavailable · transcribed with Apple Speech"
                        : "Transcribed with \(result.provider.rawValue)")
                },
                cancel: { isShowingVoiceRecorder = false }
            )
        }
        .sheet(isPresented: $isShowingFileSearch) {
            WorkspaceFileSearchSheet(
                load: { query in
                    guard let workspace else { throw APIError.invalidResponse }
                    return try await model.searchFiles(in: workspace, query: query)
                },
                select: { file in
                    appendToken("`\(file.path)`")
                }
            )
            .frame(minWidth: 560, minHeight: 480)
        }
        .sheet(isPresented: $isShowingJira) {
            JiraTicketPickerSheet(
                loadAssigned: { try await model.fetchAssignedJiraTickets() },
                lookup: { query in try await model.fetchJiraTicket(query: query) },
                select: { ticket in
                    appendJira(ticket)
                }
            )
            .frame(minWidth: 640, minHeight: 560)
        }
    }

    private var showsPiOptionsBar: Bool {
        guard let piConfiguration else { return false }
        return piConfiguration.currentModel != nil
            || piConfiguration.capabilities.listModels
            || piConfiguration.thinkingLevel != nil
            || piConfiguration.capabilities.setThinkingLevel
            || responseAudioPlayer?.isVisible == true
    }

    private var semanticControlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private var composerToolbar: some View {
        let stacksControls = composerWidth < 480 * fontScale.rawValue
        let layout = stacksControls
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if let piConfiguration, showsPiOptionsBar {
                PiComposerOptionsBar(
                    configuration: piConfiguration,
                    responseAudioPlayer: responseAudioPlayer,
                    activateResponseAudio: activateResponseAudio,
                    modelFavorites: modelFavorites
                )
            }
            HStack(spacing: 12) {
                if let piConfiguration, piConfiguration.phase == .working,
                   piConfiguration.compactionActivity == nil {
                    PiPromptComposerStatusBar(
                        disposition: effectiveDisposition,
                        availableDispositions: piConfiguration.availableDispositions,
                        canSelectDisposition: piConfiguration.isConnected,
                        canAbort: piConfiguration.canAbort,
                        selectDisposition: selectDisposition,
                        stop: stopPi,
                        showsStatusLabel: false
                    )
                }
                if destination.supportsPaneTools {
                    terminalKeysToggle
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: stacksControls || !showsPiOptionsBar ? .infinity : nil, alignment: .trailing)
        }
    }

    private var composerRow: some View {
        VStack(spacing: 0) {
            composerInput
            composerActionsLayout {
                ComposerAuxiliaryBar(
                    attach: { isShowingFileImporter = true },
                    recordVoice: { isShowingVoiceRecorder = true },
                    searchFiles: { isShowingFileSearch = true },
                    chooseJira: { isShowingJira = true },
                    voicePhase: quickVoiceCapture.phase,
                    beginVoiceHold: beginQuickVoiceCapture,
                    endVoiceHold: finishQuickVoiceCapture,
                    finishLockedVoiceCapture: finishLockedQuickVoiceCapture,
                    pasteCodeBlock: pasteCodeBlock,
                    showsTitles: true,
                    showsAttach: destination.supportsAttachments,
                    showsVoice: destination.supportsVoice,
                    showsContextTools: false,
                    canPasteCode: !isSubmitting && canControl && !isPiCompacting
                )
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 4) {
                    moreToolsButton
                    Spacer(minLength: 4)
                    trailingComposerButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
        }
        .background(HerdrTheme.input)
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(composerInputBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 9))
    }

    private var composerActionsLayout: AnyLayout {
        composerWidth < 390 * fontScale.rawValue
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 4))
    }

    private var terminalKeysToggle: some View {
        Button {
            showsTerminalKeys.toggle()
        } label: {
            Label("Terminal keys", systemImage: "keyboard")
                .herdrFont(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: HerdrTheme.minHitTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(showsTerminalKeys ? HerdrTheme.accent : HerdrTheme.muted)
        .help(showsTerminalKeys ? "Hide terminal keys" : "Show keys to control the terminal while typing")
        .accessibilityLabel("Terminal keys")
        .accessibilityValue(showsTerminalKeys ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("composer-terminal-keys-toggle")
    }

    private var moreToolsButton: some View {
        Button {
            isShowingMoreTools.toggle()
        } label: {
            Label("More", systemImage: "ellipsis")
                .herdrFont(.caption)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isShowingMoreTools ? HerdrTheme.text : HerdrTheme.mist)
        .help("Chat maintenance, workspace files, Jira context and voice dictation")
        .accessibilityLabel("More prompt tools")
        .accessibilityValue(isShowingMoreTools ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("composer-more-tools")
        .popover(isPresented: $isShowingMoreTools, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prompt tools")
                    .herdrFont(.headline, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                if destination.supportsPaneTools, let pane, pane.supportsPiSemanticChat {
                    ComposerPiMaintenanceActions(
                        isEnabled: canControl && piConfiguration?.isConnected == true && !isPiCompacting && !isSubmitting,
                        compact: {
                            isShowingMoreTools = false
                            Task { await model.compactPiChat(in: pane) }
                        },
                        reload: {
                            isShowingMoreTools = false
                            Task { await model.reloadPiSession(in: pane) }
                        }
                    )
                    Divider()
                }
                ComposerAuxiliaryBar(
                    attach: { isShowingFileImporter = true },
                    recordVoice: {
                        isShowingMoreTools = false
                        isShowingVoiceRecorder = true
                    },
                    searchFiles: {
                        isShowingMoreTools = false
                        isShowingFileSearch = true
                    },
                    chooseJira: {
                        isShowingMoreTools = false
                        isShowingJira = true
                    },
                    voicePhase: quickVoiceCapture.phase,
                    beginVoiceHold: beginQuickVoiceCapture,
                    endVoiceHold: finishQuickVoiceCapture,
                    finishLockedVoiceCapture: finishLockedQuickVoiceCapture,
                    showsTitles: true,
                    showsAttach: false,
                    showsCode: false,
                    showsVoice: false,
                    showsContextTools: destination.supportsPaneTools,
                    isVertical: true
                )
                if destination.supportsVoice {
                    Button("Start voice dictation", systemImage: "mic", action: startLockedVoiceCapture)
                        .buttonStyle(.plain)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .disabled(quickVoiceCapture.phase != .idle || !canControl || isPiCompacting)
                    Text("Click Voice for a note. Hold to dictate, and keep holding to lock recording.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 270)
            .background(HerdrTheme.elevated)
        }
    }

    @ViewBuilder
    private var voiceCaptureStatus: some View {
        if quickVoiceCapture.phase == .locked {
            HStack(spacing: 8) {
                Label("Recording locked", systemImage: "mic.fill")
                    .foregroundStyle(HerdrTheme.alert)
                Spacer()
                Button("Finish dictation", action: finishLockedQuickVoiceCapture)
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.alert, emphasis: .text))
                    .accessibilityIdentifier("composer-finish-dictation")
            }
            .herdrFont(.caption)
            .transition(semanticControlTransition)
        } else if quickVoiceCapture.phase == .transcribing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing dictation…")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .transition(semanticControlTransition)
        }
    }

    /// Mounted only on request. Narrow windows retain every key in the
    /// existing overflow menu, and keyboard routing itself is unchanged.
    private var composerToolRow: some View {
        Group {
            switch toolRowFit {
            case .automatic:
                ViewThatFits(in: .horizontal) {
                    keyRow(showsLabels: true)
                    keyRow(showsLabels: false)
                    keyRow(
                        showsLabels: false,
                        keys: TerminalPresetKey.primaryRow,
                        overflow: TerminalPresetKey.secondaryRow
                    )
                }
            case .pinnedWidest:
                keyRow(showsLabels: true)
            }
        }
        .accessibilityIdentifier("composer-tool-row")
    }

    @ViewBuilder
    private func keyRow(
        showsLabels: Bool,
        keys: [TerminalPresetKey] = TerminalPresetKey.deckRow,
        overflow: [TerminalPresetKey] = []
    ) -> some View {
        if let pane {
            TerminalKeyDeck(
                model: model,
                pane: pane,
                keys: keys,
                overflow: overflow,
                showsLabels: showsLabels
            )
        }
    }

    private var composerInput: some View {
        Group {
            if isCTALockedCapture {
                HerdrVoiceWaveform(
                    samples: quickVoiceCapture.samples,
                    isRecording: true,
                    showsContainer: false
                )
                .padding(.horizontal, 13)
            } else if isCTATranscribing {
                ProgressView()
                    .tint(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ComposerDraftEditor(placeholder: placeholder, text: $draft, pasteCode: pasteCodeBlock, editorTarget: editorTarget)
                    .herdrFont(size: 13)
                    .foregroundStyle(HerdrTheme.text)
                    .focused($isFocused)
                    .onSubmit(handleSubmit)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        moveSkillsHighlight(by: -1)
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        moveSkillsHighlight(by: 1)
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard skillsPalette.isVisible else { return .ignored }
                        acceptSkill()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        // Leaves the typed text exactly where it is; only the
                        // HUD goes away, and this `$token` will not raise it
                        // again.
                        guard skillsPalette.isVisible else { return .ignored }
                        skillsPalette.dismiss()
                        return .handled
                    }
                    .onKeyPress(.space, phases: .down) { press in
                        // A space is the user saying "not a skill". The HUD
                        // leaves and the space types normally, so this handler
                        // deliberately reports `.ignored`.
                        guard skillsPalette.isVisible, press.modifiers.isEmpty else { return .ignored }
                        skillsPalette.dismiss()
                        return .ignored
                    }
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
                    .padding(.bottom, 4)
                    .frame(minHeight: 50, alignment: .topLeading)
                    .disabled(isSubmitting || !canControl || isPiCompacting)
            }
        }
        .frame(minHeight: 50)
        .frame(maxWidth: .infinity)
        .shadow(
            color: quickVoiceCapture.phase == .locked
                ? HerdrTheme.alert.opacity(isLockPulsing && !reduceMotion ? 0.62 : 0.28)
                : .clear,
            radius: quickVoiceCapture.phase == .locked ? 8 : 0
        )
        .animation(
            // Keep the resting state animation-free, per HerdrPulseGlow's policy.
            (reduceMotion || !isLockPulsing)
                ? nil
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .accessibilityIdentifier("prompt-composer")
    }

    private var trailingComposerButton: some View {
        Button(action: handleTrailingComposerAction) {
            Group {
                if isCTACaptureInProgress {
                    Image(systemName: "stop.fill")
                } else if isSubmitting {
                    ProgressView()
                        .tint(HerdrTheme.ink)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .frame(width: 30, height: 30)
            .background(isCTALockedCapture ? HerdrTheme.alert : HerdrTheme.primaryAction)
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        }
        .herdrFont(.headline, weight: .bold)
        .foregroundStyle(HerdrTheme.ink)
        .scaleEffect(isCTALockedCapture && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(trailingComposerOpacity)
        .animation(
            (reduceMotion || !isLockPulsing)
                ? nil
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .buttonStyle(.plain)
        .disabled(
            (isPiCompacting && !isCTALockedCapture)
                || isCTATranscribing
                || (!isCTALockedCapture && !canSend)
        )
        .help(trailingComposerAccessibilityHint)
        .accessibilityLabel(trailingComposerAccessibilityLabel)
        .accessibilityHint(trailingComposerAccessibilityHint)
        .accessibilityIdentifier("prompt-send")
    }

    private var placeholder: String {
        if let piConfiguration {
            return piConfiguration.placeholder(for: effectiveDisposition)
        }
        return destination.placeholder
    }

    private var canControl: Bool { destination.canControl }

    private var draftContainsDictation: Bool {
        persistedDictation?.wrappedValue ?? localDraftContainsDictation
    }

    private func setDraftContainsDictation(_ value: Bool) {
        if let persistedDictation {
            persistedDictation.wrappedValue = value
        } else {
            localDraftContainsDictation = value
        }
    }

    private var isSubmitting: Bool { destination.isSubmitting }

    private var isPiCompacting: Bool { destination.isBusy }

    private var sendAccessibilityHint: String {
        if piConfiguration != nil { return "Sends using \(effectiveDisposition.label.lowercased()) mode" }
        return destination.sendAccessibilityHint
    }

    private var effectiveDisposition: PiPromptDisposition {
        guard let piConfiguration else { return .prompt }
        return piConfiguration.availableDispositions.contains(disposition)
            ? disposition
            : piConfiguration.preferredDisposition
    }

    private var canSend: Bool {
        PromptComposerSubmission.isReady(
            draft: draft,
            attachments: attachments,
            quoteCount: quotes.count,
            conversationReferenceCount: stagedConversationReferences.count,
            isSubmitting: isSubmitting,
            canControl: canControl,
            dispositionIsAvailable: piConfiguration?.availableDispositions.contains(effectiveDisposition) ?? true
        )
    }

    private var isCTALockedCapture: Bool {
        isCTACapture && quickVoiceCapture.phase == .locked
    }

    private var isCTATranscribing: Bool {
        isCTACapture && quickVoiceCapture.phase == .transcribing
    }

    private var isCTACaptureInProgress: Bool {
        isCTALockedCapture || isCTATranscribing
    }

    private var composerInputBorder: Color {
        quickVoiceCapture.phase == .locked
            ? HerdrTheme.alert
            : isFocused ? HerdrTheme.accent : HerdrTheme.separator
    }

    private var trailingComposerOpacity: Double {
        if isCTALockedCapture { return 1 }
        if isCTATranscribing { return 0.45 }
        return canSend ? 1 : 0.45
    }

    private var trailingComposerAccessibilityLabel: String {
        if isCTALockedCapture { return "Stop voice dictation" }
        if isCTATranscribing { return "Transcribing voice dictation" }
        if piConfiguration != nil { return effectiveDisposition.label }
        return destination.sendAccessibilityLabel
    }

    private var trailingComposerAccessibilityHint: String {
        if isCTALockedCapture { return "Stops recording and transcribes the dictation" }
        if isCTATranscribing { return "Voice dictation is being transcribed" }
        return sendAccessibilityHint
    }

    /// Return sends, and every modified Return breaks the line.
    /// `ComposerReturnKeyRouter` holds the rules; this only turns its verdict
    /// into a `KeyPress.Result`.
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerReturnKeyRouter.outcome(
            for: press,
            isSkillsPaletteVisible: skillsPalette.isVisible
        ) {
        case .acceptSkill:
            acceptSkill()
            return .handled
        case .insertNewline:
            ComposerNewlineInserter.insertNewline(in: $draft)
            return .handled
        case .send:
            send()
            return .handled
        }
    }

    /// `onSubmit` is the backstop for a Return that never reached
    /// `handleReturnKey`. On a vertical-axis `TextField` that specifically
    /// includes ⌘Return, which SwiftUI claims as the field's default action, so
    /// this has to make the same newline decision or the fix leaks.
    private func handleSubmit() {
        switch ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: skillsPalette.isVisible
        ) {
        case .insertNewline:
            ComposerNewlineInserter.insertNewline(in: $draft)
        case .acceptSkill:
            acceptSkill()
        case .send:
            send()
        }
    }

    // MARK: - `$` skills HUD

    /// Re-runs the palette against the current draft after every edit.
    ///
    /// `TextField` publishes no caret on macOS, so the caret is taken to be the
    /// end of the draft — true for typing, and the worst a mid-string edit can
    /// do is leave the HUD closed.
    private func updateSkillsPalette() {
        skillsPalette.textDidChange(draft, caret: draft.count)
        loadSkillsIfNeeded()
    }

    /// Fetches the workspace's skills the first time a `$` token appears, then
    /// re-filters — the HUD fills itself in mid-keystroke rather than making
    /// the first `$` of a session a dead one. Failures stay silent: this is an
    /// accelerator, and `WorkspaceSkillsView` is where skills errors belong.
    private func loadSkillsIfNeeded() {
        guard !didLoadSkills,
              !isLoadingSkills,
              ComposerSkillsPalette.tokenStart(in: Array(draft), caret: draft.count) != nil
        else { return }
        guard destination.supportsPaneTools, let workspace else { return }
        isLoadingSkills = true
        let destinationID = destination.id
        Task {
            defer { if destination.id == destinationID { isLoadingSkills = false } }
            guard let response = try? await model.fetchSkills(for: workspace),
                  destination.id == destinationID,
                  destination.acceptsCompletion() else { return }
            didLoadSkills = true
            skillsPalette.replaceSkills(
                response.resolvedProjectSkills + response.resolvedUserSkills
            )
        }
    }

    private func moveSkillsHighlight(by delta: Int) -> KeyPress.Result {
        guard skillsPalette.isVisible else { return .ignored }
        skillsPalette.moveHighlight(by: delta)
        return .handled
    }

    private func acceptSkill() {
        apply(skillsPalette.accept())
    }

    private func acceptSkill(at index: Int) {
        apply(skillsPalette.accept(at: index))
    }

    private func apply(_ acceptance: ComposerSkillsPalette.Acceptance?) {
        guard let acceptance else { return }
        draft = acceptance.text
        hapticPulse.fire(.selection)
        isFocused = true
    }

    private func appendToken(_ token: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        isFocused = true
    }

    private func pasteCodeBlock() {
        guard !isSubmitting, canControl, !isPiCompacting else { return }
        let selection = editorTarget.captureSelection(for: draft)
        Task {
            guard !isSubmitting, canControl, !isPiCompacting else { return }
            if await ComposerCodeBlockPaste.paste(into: $draft, pasteboard: codePasteboard, selection: selection) {
                isFocused = true
            } else {
                destination.reportToast("Copy some text before pasting a code block")
            }
        }
    }

    private func appendTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? cleaned : "\(existing)\n\n\(cleaned)"
        setDraftContainsDictation(true)
        isFocused = true
    }

    private func beginQuickVoiceCapture() {
        guard !isShowingVoiceRecorder, quickVoiceCapture.phase == .idle else { return }
        hapticPulse.fire(.recordingStarted)
        quickVoiceCapture.beginHold()
    }

    private func finishQuickVoiceCapture() {
        guard quickVoiceCapture.phase != .locked else { return }
        completeQuickVoiceCapture()
    }

    private func finishLockedQuickVoiceCapture() {
        guard quickVoiceCapture.phase == .locked else { return }
        completeQuickVoiceCapture()
    }

    private func completeQuickVoiceCapture() {
        Task {
            hapticPulse.fire(.recordingStopped)
            let destinationID = destination.id
            let outcome = await quickVoiceCapture.endHold { url in
                try await destination.transcribe(url)
            }
            guard destination.id == destinationID, destination.acceptsCompletion() else { return }
            switch outcome {
            case .cancelled:
                break
            case .tooShort:
                destination.reportToast("Hold the mic to dictate")
            case let .transcript(result):
                appendTranscript(result.text)
                hapticPulse.fire(.transcriptionSucceeded)
                destination.reportToast(result.usedFallback
                    ? "Parakeet unavailable · transcribed with Apple Speech"
                    : "Transcribed with \(result.provider.rawValue)")
            case let .failure(message):
                hapticPulse.fire(.failed)
                destination.reportError(message)
            }
            isCTACapture = false
        }
    }

    private func startLockedVoiceCapture() {
        guard quickVoiceCapture.phase == .idle, canControl, !isPiCompacting else { return }
        isShowingMoreTools = false
        isCTACapture = true
        quickVoiceCapture.beginLocked()
    }

    private func handleTrailingComposerAction() {
        if isCTALockedCapture {
            finishLockedQuickVoiceCapture()
        } else {
            send()
        }
    }

    private func appendJira(_ ticket: JiraTicket) {
        let block = """
        Jira: \(ticket.key) · \(ticket.title)
        Status: \(ticket.status) · Priority: \(ticket.priority)
        \(ticket.url)
        """
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed.isEmpty ? block : "\(trimmed)\n\n\(block)"
        isFocused = true
    }

    private func queueAttachments(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard !urls.isEmpty else { return }
        guard destination.supportsAttachments, destination.acceptsCompletion() else {
            removeTemporarySources(urls, ownership: ownership)
            destination.reportError("Attachments are unavailable for this destination.")
            return
        }
        do {
            let candidates = try urls.map {
                try AttachmentPolicy.candidate(for: $0, ownership: ownership)
            }
            try AttachmentPolicy.validate(
                existingAttachments: attachments,
                incomingCandidates: candidates
            )
            enqueue(candidates)
        } catch {
            removeTemporarySources(urls, ownership: ownership)
            destination.reportError(error.localizedDescription)
        }
    }

    private func enqueue(_ candidates: [AttachmentCandidate]) {
        let queued = candidates.map { candidate in
            TerminalAttachment(
                id: UUID(),
                filename: candidate.filename,
                sourceURL: candidate.sourceURL,
                byteCount: candidate.byteCount,
                sourceOwnership: candidate.ownership,
                status: .uploading,
                uploaded: nil,
                error: nil
            )
        }
        attachments.append(contentsOf: queued)
        queued.forEach(upload)
    }

    private func upload(_ item: TerminalAttachment) {
        let url = item.sourceURL
        let destinationID = destination.id
        Task {
            do {
                let uploaded = try await destination.upload(url, contentType(for: url))
                guard destination.id == destinationID, destination.acceptsCompletion() else {
                    item.removeSourceFileIfOwned()
                    return
                }
                attachments = PromptComposerSubmission.applyingUploadSuccess(
                    uploaded,
                    itemID: item.id,
                    to: attachments
                )
                item.removeSourceFileIfOwned()
            } catch {
                guard destination.id == destinationID, destination.acceptsCompletion() else {
                    item.removeSourceFileIfOwned()
                    return
                }
                attachments = PromptComposerSubmission.applyingUploadFailure(
                    error.localizedDescription,
                    itemID: item.id,
                    to: attachments
                )
            }
        }
    }

    private func retryAttachment(_ item: TerminalAttachment) {
        updateAttachment(item.id) {
            $0.error = nil
            $0.status = .uploading
        }
        upload(item)
    }

    private func removeAttachment(_ item: TerminalAttachment) {
        item.removeSourceFileIfOwned()
        attachments.removeAll { $0.id == item.id }
    }

    private func updateAttachment(
        _ id: UUID,
        update: (inout TerminalAttachment) -> Void
    ) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        update(&attachments[index])
    }

    private func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func removeTemporarySources(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard ownership == .appTemporary else { return }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func send() {
        guard canSend, destination.isCurrent() else { return }
        let destinationID = destination.id
        let draftToSend = draft
        let attachmentsToSend = attachments.filter { $0.status == .uploaded && $0.uploadedPath != nil }
        let quotesToSend = quotes
        let referencesToSend = stagedConversationReferences
        let sentDictation = draftContainsDictation
        let message = PromptComposerSubmission.payload(
            draft: draftToSend,
            attachments: attachmentsToSend,
            quotes: quotesToSend,
            references: referencesToSend,
            containsDictation: sentDictation
        )
        let piConfiguration = self.piConfiguration
        let disposition = effectiveDisposition

        Task {
            let didSend = if let piConfiguration {
                await piConfiguration.submit(message, disposition)
            } else {
                await destination.submit(message)
            }
            guard destination.id == destinationID, destination.acceptsCompletion() else { return }

            if didSend {
                var currentDraft = draft
                var currentAttachments = attachments
                var currentQuotes = quotes
                var currentContainsDictation = draftContainsDictation
                PromptComposerSubmission.consumeAccepted(
                    sentDraft: draftToSend,
                    sentAttachmentIDs: Set(attachmentsToSend.map(\.id)),
                    sentQuoteIDs: Set(quotesToSend.map(\.id)),
                    sentContainsDictation: sentDictation,
                    draft: &currentDraft,
                    attachments: &currentAttachments,
                    quotes: &currentQuotes,
                    containsDictation: &currentContainsDictation
                )
                draft = currentDraft
                attachments = currentAttachments
                quotes = currentQuotes
                setDraftContainsDictation(currentContainsDictation)
                if let pane {
                    let sentReferenceIDs = Set(referencesToSend.map(\.id))
                    model.removeConversationReferences(sentReferenceIDs, from: pane.id)
                }
                hapticPulse.fire(.promptSent)
            } else {
                hapticPulse.fire(.failed)
            }
        }
    }

    private func selectDisposition(_ selection: PiPromptDisposition) {
        disposition = selection
        hapticPulse.fire(.selection)
    }

    private func stopPi() {
        guard let piConfiguration, piConfiguration.canAbort else { return }
        Task {
            let succeeded = await piConfiguration.abort()
            hapticPulse.fire(succeeded ? .stopped : .failed)
        }
    }
}
