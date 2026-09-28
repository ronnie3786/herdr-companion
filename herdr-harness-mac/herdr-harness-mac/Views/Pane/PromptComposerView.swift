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
    /// The box's first line: machine · workspace · tab, the working folder,
    /// and the context ring (pane composers).
    let contextLine: ComposerContextLine?
    /// A host-supplied first line in place of `contextLine` (First Mate).
    let contextAccessory: ComposerAccessory?
    /// Host controls placed after More in the toolbar (First Mate's model).
    let toolbarAccessory: ComposerAccessory?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.composerAddMenuInitiallyPresented) private var addMenuInitiallyPresented
    @State private var composerWidth: CGFloat = .infinity
    @State private var editorTarget = ComposerEditorTarget()
    @FocusState private var isFocused: Bool
    @State private var isShowingFileImporter = false
    @State private var isShowingVoiceRecorder = false
    @State private var isShowingFileSearch = false
    @State private var isShowingJira = false
    @State private var isShowingMoreTools = false
    @State private var isShowingAddMenu = false
    @State private var showsTerminalKeys = false
    @State private var isFileDropTargeted = false
    @State private var isConversationDropTargeted = false
    @State private var disposition: PiPromptDisposition = .prompt
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var dictationSession = PromptComposerDictationSession()
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
        contextLine = ComposerContextLine(model: model, pane: pane)
        contextAccessory = nil
        toolbarAccessory = nil
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
        codePasteboard: NSPasteboard = .general,
        contextAccessory: ComposerAccessory? = nil,
        toolbarAccessory: ComposerAccessory? = nil
    ) {
        self.model = model
        contextLine = nil
        self.contextAccessory = contextAccessory
        self.toolbarAccessory = toolbarAccessory
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

            composerBox
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
            if addMenuInitiallyPresented { isShowingAddMenu = true }
        }
        .onDisappear {
            dictationSession.cancel()
        }
        .onChange(of: destination.id) {
            dictationSession.cancel()
            skillsPalette.dismiss()
            isShowingMoreTools = false
            showsTerminalKeys = false
            if case .none = persistedDictation { localDraftContainsDictation = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dictationSession.cancel()
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
                // A rule only: a wash over the composer would drop the model
                // pill's text under 4.5:1 over the dusk glass.
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer)
                    .strokeBorder(HerdrTheme.accent.opacity(0.6), lineWidth: 1)
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
    }

    private var semanticControlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    /// MonoCode's composer: one 8pt-radius box (ink 3%, 10% outline, 20% while
    /// focused) holding the context line, the prompt, and a 26pt toolbar.
    private var composerBox: some View {
        VStack(spacing: 0) {
            contextLineView
            composerInput
            composerTools
        }
        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer)
                .strokeBorder(composerInputBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.Radius.composer))
    }

    private var hasContextLine: Bool { contextLine != nil || contextAccessory != nil }

    @ViewBuilder
    private var contextLineView: some View {
        if let contextAccessory {
            contextAccessory.view
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, minHeight: HerdrTheme.minHitTarget, alignment: .leading)
        } else if let contextLine {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .herdrFont(size: 13)
                        .foregroundStyle(HerdrTheme.iconTint)
                        .accessibilityHidden(true)
                    Text(contextLine.machine)
                        .accessibilityIdentifier("pane-session-machine")
                    if let location = contextLine.location {
                        Text("· \(location)")
                    }
                }
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.tertiaryText)
                .lineLimit(1)
                .layoutPriority(1)

                if let path = contextLine.path, !path.isEmpty {
                    PanePathButton(path: path, reportFailure: { model.toastMessage = $0 })
                        .padding(.leading, -6)
                }

                Spacer(minLength: 8)

                PiContextRing(usage: piConfiguration?.contextUsage, cost: piConfiguration?.sessionCost)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .frame(minHeight: HerdrTheme.minHitTarget)
        }
    }

    /// Left: `+`, Voice, More, model + effort, host accessory. Right: listen,
    /// Terminal keys, Steer, Stop, and the primary button. Narrow composers
    /// put the right cluster on its own trailing line.
    private var composerTools: some View {
        let isNarrow = composerWidth < 460 * fontScale.rawValue
        let layout = isNarrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            HStack(spacing: 4) {
                addMenuButton
                if destination.supportsVoice {
                    switch destination.voicePolicy.externalVoiceRole {
                    case .openRecorder:
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
                            showsTitles: false,
                            showsAttach: false,
                            showsCode: false,
                            showsVoice: true,
                            showsContextTools: false,
                            canPasteCode: canPasteCode
                        )
                        .fixedSize()
                    case .dictate:
                        dictationMicrophoneButton
                    }
                }
                moreToolsButton
                if let piConfiguration, showsPiOptionsBar {
                    PiComposerOptionsBar(configuration: piConfiguration, modelFavorites: modelFavorites)
                        .layoutPriority(-1)
                }
                if let toolbarAccessory {
                    toolbarAccessory.view
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if let responseAudioPlayer, let activateResponseAudio {
                    ResponseAudioControlsView(
                        player: responseAudioPlayer,
                        showsTitles: false,
                        activate: activateResponseAudio
                    )
                }
                if destination.supportsPaneTools {
                    terminalKeysToggle
                }
                if let piConfiguration, piConfiguration.phase == .working,
                   piConfiguration.compactionActivity == nil {
                    PiPromptComposerStatusBar(
                        disposition: effectiveDisposition,
                        availableDispositions: piConfiguration.availableDispositions,
                        canSelectDisposition: piConfiguration.isConnected,
                        canAbort: piConfiguration.canAbort,
                        selectDisposition: selectDisposition,
                        stop: stopPi,
                        showsStatusLabel: false,
                        showsStop: false
                    )
                    if primaryMode == .send {
                        // A typed draft owns the primary button; Stop stays one click away.
                        Button("Stop", systemImage: "stop.fill", action: stopPi)
                            .buttonStyle(HerdrIconButtonStyle(tint: HerdrTheme.alert))
                            .disabled(!piConfiguration.canAbort)
                            .help("Stop Pi's current turn")
                            .accessibilityIdentifier("pi-chat-stop")
                    } else if primaryMode != .stopTurn {
                        // While dictation or a submission owns the primary button,
                        // Stop turn is spelled out so it never reads as "stop
                        // recording".
                        Button("Stop turn", systemImage: "stop.fill", action: stopPi)
                            .labelStyle(DashboardInlineLabelStyle(spacing: 4))
                            .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.small))
                            .disabled(!piConfiguration.canAbort)
                            .help("Stop Pi's current turn")
                            .accessibilityIdentifier("pi-chat-stop")
                    }
                }
                primaryButton
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: isNarrow ? .infinity : nil, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 7)
    }

    private var canPasteCode: Bool {
        !isSubmitting && canControl && !isPiCompacting
    }

    /// `+`: Attach and Paste code, with their hints, in a small popover.
    private var addMenuButton: some View {
        Button("Add to prompt", systemImage: "plus") {
            isShowingAddMenu.toggle()
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: isShowingAddMenu, restingFill: HerdrTheme.selectedFill))
        .help("Attach files or paste code")
        .accessibilityValue(isShowingAddMenu ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("composer-add-menu")
        .popover(isPresented: $isShowingAddMenu, arrowEdge: .top) {
            ComposerAddMenuContent(
                showsAttach: destination.supportsAttachments,
                canPasteCode: canPasteCode,
                attach: {
                    isShowingAddMenu = false
                    isShowingFileImporter = true
                },
                pasteCode: {
                    isShowingAddMenu = false
                    pasteCodeBlock()
                }
            )
        }
    }

    private var terminalKeysToggle: some View {
        Button("Terminal keys", systemImage: "keyboard") {
            showsTerminalKeys.toggle()
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: showsTerminalKeys))
        .help(showsTerminalKeys ? "Hide terminal keys" : "Show keys to control the terminal while typing")
        .accessibilityLabel("Terminal keys")
        .accessibilityValue(showsTerminalKeys ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("composer-terminal-keys-toggle")
    }

    private var moreToolsButton: some View {
        Button("More", systemImage: "ellipsis") {
            isShowingMoreTools.toggle()
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: isShowingMoreTools))
        .help("Chat maintenance, workspace files, Jira context and voice dictation")
        .accessibilityLabel("More prompt tools")
        .accessibilityValue(isShowingMoreTools ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("composer-more-tools")
        .popover(isPresented: $isShowingMoreTools, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HerdrMicroLabel(text: "Prompt tools")
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
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
                    Rectangle()
                        .fill(HerdrTheme.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 4)
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
                    switch destination.voicePolicy.menuVoiceRole {
                    case .dictate:
                        ComposerPopoverRow(
                            title: "Start voice dictation",
                            systemImage: "mic",
                            hint: "Click Voice for a note. Hold to dictate, and keep holding to lock recording.",
                            action: startLockedVoiceCapture
                        )
                        .disabled(quickVoiceCapture.phase != .idle || !canControl || isPiCompacting || isSubmitting)
                        .accessibilityIdentifier("composer-start-dictation")
                    case .openRecorder:
                        ComposerPopoverRow(
                            title: "Record a voice note",
                            systemImage: "mic",
                            hint: "Record, preview, attach the audio, or transcribe it into the prompt.",
                            action: {
                                isShowingMoreTools = false
                                isShowingVoiceRecorder = true
                            }
                        )
                        .disabled(quickVoiceCapture.phase != .idle || !canControl || isPiCompacting || isSubmitting)
                        .accessibilityIdentifier("composer-record-voice-note")
                    }
                }
            }
            .padding(6)
            .frame(width: 260)
        }
    }

    @ViewBuilder
    private var voiceCaptureStatus: some View {
        if quickVoiceCapture.phase == .locked {
            HStack(spacing: 8) {
                Label(
                    dictationSubmitsOnStop ? "Listening" : "Recording locked",
                    systemImage: "mic.fill"
                )
                .foregroundStyle(HerdrTheme.alert)
                if dictationSubmitsOnStop {
                    Text("Stop transcribes and sends")
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                Button(
                    dictationSubmitsOnStop ? "Stop and send" : "Finish dictation",
                    action: stopVoiceCapture
                )
                .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.alert, emphasis: .text))
                .help(dictationSubmitsOnStop
                    ? "Stops recording, transcribes the dictation, and sends the prompt"
                    : "Stops recording and transcribes the dictation")
                .accessibilityIdentifier("composer-finish-dictation")
            }
            .herdrFont(size: HerdrTheme.TextSize.small)
            .transition(semanticControlTransition)
        } else if quickVoiceCapture.phase == .transcribing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(dictationSubmitsOnStop ? "Transcribing dictation, then sending…" : "Transcribing dictation…")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .transition(semanticControlTransition)
        }
    }

    /// First Mate's external microphone: one click starts click-to-stop
    /// dictation, and the same control becomes Stop, which transcribes and
    /// sends. Legacy destinations keep the recorder and hold gesture instead.
    private var dictationMicrophoneButton: some View {
        let isRecording = isCTALockedCapture
        let isTranscribing = isCTATranscribing
        return Button(action: handleDictationMicrophoneTap) {
            if isTranscribing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: isRecording ? "stop.fill" : "mic")
            }
        }
        .buttonStyle(HerdrIconButtonStyle(
            isActive: isRecording,
            tint: isRecording ? HerdrTheme.alert : HerdrTheme.iconTint
        ))
        .disabled(isTranscribing || (!isRecording && (isSubmitting || !canControl || isPiCompacting)))
        .help(dictationMicrophoneHelp)
        .accessibilityLabel(dictationMicrophoneLabel)
        .accessibilityHint(dictationMicrophoneHint)
        .accessibilityIdentifier("composer-record-voice")
    }

    private func handleDictationMicrophoneTap() {
        guard canControl, !isPiCompacting, !isSubmitting else { return }
        switch dictationSession.externalMicAction() {
        case .start:
            isShowingMoreTools = false
            isCTACapture = true
        case .stop:
            finishLockedQuickVoiceCapture()
        case .ignored:
            break
        }
    }

    private var dictationMicrophoneLabel: String {
        if isCTALockedCapture { return "Stop dictation and send" }
        if isCTATranscribing { return "Transcribing dictation" }
        return "Start dictation"
    }

    private var dictationMicrophoneHelp: String {
        if isCTALockedCapture { return "Stops recording, transcribes, and sends" }
        if isCTATranscribing { return "Transcribing dictation" }
        return "Start dictation · click Stop to transcribe and send"
    }

    private var dictationMicrophoneHint: String {
        if isCTALockedCapture { return "Finishes recording, transcribes the dictation, and sends the prompt" }
        if isCTATranscribing { return "No action is available while dictation is transcribed" }
        return "Starts recording without opening More"
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
                .padding(.horizontal, 12)
            } else if isCTATranscribing {
                ProgressView()
                    .tint(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, minHeight: 46 * fontScale.rawValue)
            } else {
                ComposerDraftEditor(
                    placeholder: placeholder,
                    text: $draft,
                    pasteCode: pasteCodeBlock,
                    editorTarget: editorTarget,
                    lineSpacing: HerdrProse.lineSpacing(size: HerdrTheme.TextSize.reading, lineHeight: 22, scale: fontScale)
                )
                    .herdrFont(size: HerdrTheme.TextSize.reading)
                    .foregroundStyle(HerdrTheme.primaryText)
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
                    // The editor adds about 5pt of its own inset.
                    .padding(.horizontal, 7)
                    .padding(.top, hasContextLine ? 4 : 10)
                    .padding(.bottom, 6)
                    .frame(minHeight: 46 * fontScale.rawValue, alignment: .topLeading)
                    .disabled(isSubmitting || !canControl || isPiCompacting)
            }
        }
        .frame(minHeight: 46 * fontScale.rawValue)
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

    private enum PrimaryMode { case stopCapture, transcribing, submitting, stopTurn, send }

    /// MonoCode's rule: while Pi works and the prompt is empty, the primary
    /// button is Stop. Any draft content (text, attachments, quotes or staged
    /// references) keeps it Send, even while that draft cannot send yet, so
    /// the Send position never aborts a turn by surprise.
    private var primaryMode: PrimaryMode {
        if isCTALockedCapture { return .stopCapture }
        if isCTATranscribing { return .transcribing }
        if isSubmitting { return .submitting }
        if let piConfiguration, piConfiguration.phase == .working,
           piConfiguration.compactionActivity == nil, !hasDraftContent {
            return .stopTurn
        }
        return .send
    }

    private var hasDraftContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty || !quotes.isEmpty || !stagedConversationReferences.isEmpty
    }

    @ViewBuilder
    private var primaryButton: some View {
        if primaryMode == .stopTurn {
            Button(action: stopPi) {
                RoundedRectangle(cornerRadius: 2)
                    .frame(width: 9 * fontScale.rawValue, height: 9 * fontScale.rawValue)
            }
            .buttonStyle(HerdrPrimarySquareButtonStyle())
            .disabled(piConfiguration?.canAbort != true)
            .help("Stop Pi's current turn")
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("pi-chat-stop")
        } else {
            trailingComposerButton
        }
    }

    private var trailingComposerButton: some View {
        Button(action: handleTrailingComposerAction) {
            Group {
                if isCTACaptureInProgress {
                    Image(systemName: "stop.fill")
                } else if isSubmitting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(HerdrTheme.onPrimary)
                } else {
                    Image(systemName: "arrow.up")
                }
            }
        }
        .buttonStyle(HerdrPrimarySquareButtonStyle(fill: isCTALockedCapture ? HerdrTheme.alert : nil))
        .scaleEffect(isCTALockedCapture && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .animation(
            (reduceMotion || !isLockPulsing)
                ? nil
                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
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

    /// The capture shared by the legacy hold gesture and the click-to-dictate
    /// microphone. `PromptComposerDictationSession` wraps it with the
    /// exactly-once completion and explicit-stop intent.
    private var quickVoiceCapture: HerdrQuickVoiceCapture { dictationSession.capture }

    /// True only where an explicit inline-dictation Stop also submits.
    private var dictationSubmitsOnStop: Bool {
        destination.voicePolicy.submitsOnExplicitStop
    }

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
            : isFocused ? HerdrTheme.focusOutline : HerdrTheme.outline
    }

    private var trailingComposerAccessibilityLabel: String {
        if isCTALockedCapture {
            return dictationSubmitsOnStop ? "Stop dictation and send" : "Stop voice dictation"
        }
        if isCTATranscribing { return "Transcribing voice dictation" }
        if piConfiguration != nil { return effectiveDisposition.label }
        return destination.sendAccessibilityLabel
    }

    private var trailingComposerAccessibilityHint: String {
        if isCTALockedCapture {
            return dictationSubmitsOnStop
                ? "Stops recording, transcribes the dictation, and sends the prompt"
                : "Stops recording and transcribes the dictation"
        }
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
        guard let updated = PromptComposerDictationSession.appending(transcript, to: draft) else { return }
        draft = updated
        setDraftContainsDictation(true)
        isFocused = true
    }

    private func beginQuickVoiceCapture() {
        guard !isShowingVoiceRecorder, quickVoiceCapture.phase == .idle else { return }
        hapticPulse.fire(.recordingStarted)
        quickVoiceCapture.beginHold()
    }

    /// Release of the legacy hold-to-dictate gesture. Holds retain their
    /// append-only contract on every destination.
    private func finishQuickVoiceCapture() {
        guard quickVoiceCapture.phase != .locked else { return }
        completeVoiceCapture()
    }

    /// Finishes a locked capture without recording an explicit Stop. The
    /// recorder's automatic duration limit reaches this path, so it can never
    /// authorize a First Mate send on its own.
    private func finishLockedQuickVoiceCapture() {
        guard quickVoiceCapture.phase == .locked else { return }
        completeVoiceCapture()
    }

    /// Converges every explicit Stop affordance (the external microphone, the
    /// primary button, and the status bar) on one guarded operation. Only a
    /// click here records the auto-submit intent, and it is recorded before
    /// the transcription suspends.
    private func stopVoiceCapture() {
        if dictationSubmitsOnStop {
            _ = dictationSession.beginExplicitStop()
        }
        finishLockedQuickVoiceCapture()
    }

    private func completeVoiceCapture() {
        Task {
            hapticPulse.fire(.recordingStopped)
            let outcome = await dictationSession.finish(dictationCompletion)
            applyDictationOutcome(outcome)
        }
    }

    /// The destination-bound operations for one dictation completion. The
    /// session appends the transcript and, only when the explicit Stop intent
    /// survived the await, submits through the composer's normal path.
    private var dictationCompletion: PromptComposerDictationSession.Completion {
        PromptComposerDictationSession.Completion(
            isCurrent: { destination.isCurrent() },
            acceptsCompletion: { destination.acceptsCompletion() },
            transcribe: { url in try await destination.transcribe(url) },
            appendTranscript: { transcript in appendTranscript(transcript) },
            canSubmit: { canSend && !isPiCompacting && destination.isCurrent() },
            submit: { await dispatchSubmission() },
            reportError: { destination.reportError($0) }
        )
    }

    private func applyDictationOutcome(_ outcome: PromptComposerDictationSession.Outcome) {
        isCTACapture = false
        switch outcome {
        case .cancelled, .stale:
            break
        case .tooShort:
            destination.reportToast(dictationSubmitsOnStop
                ? "That was too short to transcribe. Tap the microphone, speak, then tap Stop."
                : "Hold the mic to dictate")
        case .empty:
            destination.reportToast("No speech was detected. Nothing was added or sent.")
        case let .failed(message):
            hapticPulse.fire(.failed)
            destination.reportError(message)
        case let .retained(result), let .submitted(result):
            hapticPulse.fire(.transcriptionSucceeded)
            destination.reportToast(transcriptionToast(result))
        case .notSent:
            // The session already surfaced the actionable explanation; a failed
            // dispatch fires its own feedback haptic.
            break
        }
    }

    private func transcriptionToast(_ result: VoiceTranscription) -> String {
        result.usedFallback
            ? "Parakeet unavailable · transcribed with Apple Speech"
            : "Transcribed with \(result.provider.rawValue)"
    }

    /// The legacy More row's locked capture. It stays outside the session's
    /// explicit-stop contract, so it always transcribes into the draft only.
    private func startLockedVoiceCapture() {
        guard quickVoiceCapture.phase == .idle,
              canControl,
              !isPiCompacting,
              !isSubmitting
        else { return }
        isShowingMoreTools = false
        isCTACapture = true
        quickVoiceCapture.beginLocked()
    }

    private func handleTrailingComposerAction() {
        if isCTALockedCapture {
            stopVoiceCapture()
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
        Task { _ = await dispatchSubmission() }
    }

    /// The composer's one submission path, shared by the Send button, Return,
    /// and a completed First Mate dictation. It serializes the staged payload,
    /// awaits the destination, and consumes only the accepted identities.
    /// Returns whether the destination accepted the submission.
    @discardableResult
    private func dispatchSubmission() async -> Bool {
        // A recording or transcription must never race a submission; the
        // dictation completion itself runs after its capture is idle.
        guard quickVoiceCapture.phase == .idle else { return false }
        guard canSend, destination.isCurrent() else { return false }
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

        let didSend = if let piConfiguration {
            await piConfiguration.submit(message, disposition)
        } else {
            await destination.submit(message)
        }
        guard destination.id == destinationID, destination.acceptsCompletion() else { return didSend }

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
        return didSend
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

/// The pane composer's first line, computed by the parent so the composer
/// never observes the machine roster itself.
struct ComposerContextLine: Equatable {
    var machine: String
    var location: String?
    var path: String?

    init(machine: String, location: String? = nil, path: String? = nil) {
        self.machine = machine
        self.location = location
        self.path = path
    }

    @MainActor
    init(model: HerdrAppModel, pane: HerdrPane) {
        machine = model.machines.first(where: { $0.id == pane.machineID })?.name ?? pane.machineID
        path = pane.displayPath.isEmpty ? nil : pane.displayPath
        if let workspace = model.workspace(containing: pane) {
            if let tab = workspace.tabs.first(where: { $0.id == pane.scopedTabID }) {
                location = "\(workspace.label) · \(tab.label)"
            } else {
                location = workspace.label
            }
        } else {
            location = pane.workspaceID
        }
    }
}

/// Host content placed in the composer, compared by `key` alone so the
/// composer's `.equatable()` still refreshes when the host's state changes.
/// Keys an accessory by any Equatable value (feature state, contexts) so
/// `ComposerAccessory` can compare hosts that are not Hashable.
struct ComposerAccessoryKey<Value: Equatable>: Hashable {
    let value: Value
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) {}
}

struct ComposerAccessory: Equatable {
    let key: AnyHashable
    let view: AnyView

    init(key: AnyHashable, @ViewBuilder content: () -> some View) {
        self.key = key
        view = AnyView(content())
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

/// The `+` popover: Attach and Paste code with their hints.
struct ComposerAddMenuContent: View {
    let showsAttach: Bool
    let canPasteCode: Bool
    let attach: () -> Void
    let pasteCode: () -> Void
    var attachIdentifier = "composer-attach-file"
    var pasteIdentifier = "composer-code-block-paste"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HerdrMicroLabel(text: "Add")
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
            if showsAttach {
                ComposerPopoverRow(
                    title: "Attach files",
                    systemImage: "paperclip",
                    hint: "Or drop files onto the composer",
                    accessibilityLabel: "Attach a file",
                    action: attach
                )
                .help("Attach files to this prompt")
                .accessibilityIdentifier(attachIdentifier)
            }
            ComposerPopoverRow(
                title: "Paste code block",
                systemImage: "chevron.left.forwardslash.chevron.right",
                hint: "⌘⇧V in the prompt",
                accessibilityLabel: "Paste Code Block",
                action: pasteCode
            )
            .disabled(!canPasteCode)
            .help("Append clipboard as a code block (⌘⇧V in the prompt)")
            .accessibilityIdentifier(pasteIdentifier)
        }
        .padding(6)
        .frame(width: 250)
    }
}

extension EnvironmentValues {
    /// Integration tests only: open the `+` popover on appear so its real
    /// Paste code row can be clicked.
    @Entry var composerAddMenuInitiallyPresented = false
}
