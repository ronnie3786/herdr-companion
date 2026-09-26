import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudComposerView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession
    var codePasteboard: NSPasteboard = .general

    @FocusState private var isComposerFocused: Bool
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var voiceErrorMessage: String?
    @State private var isShowingFilePicker = false
    @Environment(\.herdrFontScale) private var fontScale
    @State private var composerWidth: CGFloat = .infinity
    @State private var editorTarget = ComposerEditorTarget()
    @State private var isShowingAddMenu = false
    @Environment(\.composerAddMenuInitiallyPresented) private var addMenuInitiallyPresented

    var body: some View {
        VStack(spacing: 6) {
            if session.isNewChat {
                HerdrHudWorkspaceCreationView(model: model, session: session)
            }
            if session.workspaceLaunchRecoveryMessage != nil {
                workspaceLaunchRecoveryRow
            }
            if !session.pendingAttachments.isEmpty || !session.pendingQuotes.isEmpty {
                attachmentChips
            }
            if let voiceErrorMessage, !voiceErrorMessage.isEmpty {
                Text(voiceErrorMessage)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                composerInput
                composerActionsLayout {
                    // MonoCode's tool row: +, voice, the model + effort pill.
                    HStack(spacing: 4) {
                        addMenuButton

                        Button(isVoiceCaptureActive ? "Finish" : "Voice", systemImage: isVoiceCaptureActive ? "stop.fill" : "mic", action: toggleVoiceCapture)
                            .buttonStyle(HerdrIconButtonStyle(tint: isVoiceCaptureActive ? HerdrTheme.alert : HerdrTheme.iconTint))
                            .disabled(quickVoiceCapture.phase == .transcribing)
                            .help(voiceCaptureAccessibilityLabel)
                            .accessibilityLabel(voiceCaptureAccessibilityLabel)
                            .accessibilityIdentifier("hud-mic")

                        PiModelEffortPill {
                            HerdrHudModelChip(
                                currentSelectionID: session.selectedModel,
                                availableModels: session.availableModels,
                                defaultModel: session.defaultModel,
                                isLoading: session.isLoadingModels,
                                errorMessage: session.modelsError,
                                favorites: session.modelFavorites,
                                defaultChoiceTitle: session.isNewChat ? "Machine default" : "Default",
                                selectModel: { session.setSelectedModel($0) },
                                retry: { Task { await session.loadModels(model: model) } }
                            )
                        } effort: {
                            PiThinkingLevelChip(
                                currentLevel: session.selectedThinkingLevel.rawValue,
                                isSetting: false,
                                isEnabled: true,
                                isInteractive: true,
                                selectLevel: { session.selectedThinkingLevel = $0 },
                                style: .segment
                            )
                            .accessibilityIdentifier("hud-thinking")
                            .help("Thinking level for the next HUD prompt")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 8) {
                        Spacer(minLength: 4)
                        if let thread = session.thread {
                            Text("Thread · \(thread.turnCount) turns")
                                .herdrFont(size: HerdrTheme.TextSize.caption)
                                .foregroundStyle(HerdrTheme.tertiaryText)
                                .lineLimit(1)
                        }
                        Button("Send HUD prompt", systemImage: "arrow.up", action: submit)
                            .buttonStyle(HerdrPrimarySquareButtonStyle())
                            .disabled(!canSubmit)
                            .help("Send prompt. Return sends; modified Return inserts a new line.")
                            .accessibilityLabel("Send HUD prompt")
                            .accessibilityIdentifier("hud-send")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(HerdrTheme.cardFill, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer)
                    .strokeBorder(isComposerFocused ? HerdrTheme.focusOutline : HerdrTheme.outline, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.Radius.composer))
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            composerWidth = width
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                session.addAttachments(urls)
            case let .failure(error):
                session.reportAttachmentError(error.localizedDescription)
            }
        }
        .task(id: controller.focusRequest) {
            isComposerFocused = true
        }
        .onAppear {
            if addMenuInitiallyPresented { isShowingAddMenu = true }
        }
        .onDisappear {
            quickVoiceCapture.cancel()
        }
        .onChange(of: quickVoiceCapture.recorderStatus) { _, status in
            if status == .finished, quickVoiceCapture.phase == .locked {
                finishVoiceCapture()
            }
        }
    }

    private var composerActionsLayout: AnyLayout {
        composerWidth < 340 * fontScale.rawValue
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 4))
    }

    private var workspaceLaunchRecoveryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = session.workspaceLaunchRecoveryMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hud-workspace-recovery-message")
            }
            HStack(spacing: 8) {
                if session.workspaceLaunchPaneIDForOpening() != nil {
                    Button("Open chat") {
                        controller.finishWorkspaceLaunch(session, openExistingChat: true, model: model)
                    }
                    .accessibilityIdentifier("hud-workspace-open-chat")
                }
                Button("Keep draft") { session.dismissWorkspaceLaunchRecovery() }
                    .accessibilityIdentifier("hud-workspace-keep-draft")
                Button("Start over") { controller.discardWorkspaceLaunch(session, model: model) }
                    .accessibilityIdentifier("hud-workspace-discard")
            }
            .buttonStyle(HerdrButtonStyle(kind: .outline))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addMenuButton: some View {
        Button("Add to prompt", systemImage: "plus") {
            isShowingAddMenu.toggle()
        }
        .buttonStyle(HerdrIconButtonStyle(isActive: isShowingAddMenu, restingFill: HerdrTheme.selectedFill))
        .help("Attach files or paste code")
        .accessibilityValue(isShowingAddMenu ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("hud-composer-add")
        .popover(isPresented: $isShowingAddMenu, arrowEdge: .top) {
            ComposerAddMenuContent(
                showsAttach: true,
                canPasteCode: true,
                attach: {
                    isShowingAddMenu = false
                    isShowingFilePicker = true
                },
                pasteCode: {
                    isShowingAddMenu = false
                    pasteCodeBlock()
                },
                attachIdentifier: "hud-attach-file",
                pasteIdentifier: "hud-code-block-paste"
            )
            // The HUD is a non-activating panel: the row must act on the
            // click that also makes its popover key, not need a second one.
            .allowsWindowActivationEvents(true)
        }
    }

    private func pasteCodeBlock() {
        let selection = editorTarget.captureSelection(for: session.draft)
        Task {
            if !(await ComposerCodeBlockPaste.paste(into: $session.draft, pasteboard: codePasteboard, selection: selection)) {
                session.reportAttachmentError("Copy some text before pasting a code block.")
            }
            isComposerFocused = true
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(session.pendingQuotes) { quote in
                    ChatQuoteChip(quote: quote, remove: { session.pendingQuotes.removeAll { $0.id == quote.id } })
                }
                ForEach(session.pendingAttachments) { attachment in
                    HerdrHudAttachmentChipView(
                        attachment: attachment,
                        remove: { session.removeAttachment(attachment.id) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var composerInput: some View {
        Group {
            if isVoiceCaptureActive {
                HerdrVoiceWaveform(
                    samples: quickVoiceCapture.samples,
                    isRecording: true,
                    showsContainer: false
                )
                .padding(.horizontal, 10)
            } else if quickVoiceCapture.phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.accent)
                    Text("Transcribing…")
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            } else {
                ComposerDraftEditor(
                    placeholder: session.thread == nil ? "Ask anything, or tell it what to do…" : "Reply to this thread…",
                    text: $session.draft,
                    maximumVisibleLines: 4,
                    pasteCode: pasteCodeBlock,
                    editorTarget: editorTarget
                )
                    .herdrFont(size: HerdrTheme.TextSize.reading)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .focused($isComposerFocused)
                    .onSubmit(handleSubmit)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
    }

    private var canSubmit: Bool {
        (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.pendingAttachments.isEmpty || !session.pendingQuotes.isEmpty) && !session.isRunning && !session.isLoadingHistory
            && !session.isEnding && !session.hasEnded
            && !session.needsHistoryRefresh && session.promotingExchangeIDs.isEmpty
            && !session.exchanges.contains(where: { $0.promotedPaneID != nil })
    }

    private var isVoiceCaptureActive: Bool {
        quickVoiceCapture.phase == .recording || quickVoiceCapture.phase == .locked
    }

    private var voiceCaptureAccessibilityLabel: String {
        switch quickVoiceCapture.phase {
        case .idle: "Start voice dictation"
        case .recording, .locked: "Stop voice dictation and transcribe"
        case .transcribing: "Voice dictation is transcribing"
        }
    }

    /// Shares `ComposerReturnKeyRouter` with the pane composer so the HUD and
    /// the chat composer never disagree about what Return does.
    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerReturnKeyRouter.outcome(for: press, isSkillsPaletteVisible: false) {
        case .insertNewline:
            ComposerNewlineInserter.insertNewline(in: $session.draft)
            return .handled
        case .acceptSkill, .send:
            submit()
            return .handled
        }
    }

    private func handleSubmit() {
        if ComposerReturnKeyRouter.submitOutcome(isSkillsPaletteVisible: false) == .insertNewline {
            ComposerNewlineInserter.insertNewline(in: $session.draft)
            return
        }
        submit()
    }

    private func submit() {
        guard canSubmit else { return }
        // An explicit submission outlives this view when its mini HUD takes over.
        Task { await controller.submitChat(session, model: model) }
    }

    private func toggleVoiceCapture() {
        voiceErrorMessage = nil
        switch quickVoiceCapture.phase {
        case .idle:
            quickVoiceCapture.beginLocked()
        case .recording, .locked:
            finishVoiceCapture()
        case .transcribing:
            break
        }
    }

    private func finishVoiceCapture() {
        Task {
            let outcome = await quickVoiceCapture.endHold { url in
                try await model.transcribeVoiceNote(at: url)
            }
            handleVoiceCapture(outcome)
        }
    }

    private func handleVoiceCapture(_ outcome: HerdrQuickVoiceCapture.Outcome) {
        switch outcome {
        case .cancelled:
            break
        case .tooShort:
            voiceErrorMessage = "Hold the mic a little longer."
        case let .failure(message):
            voiceErrorMessage = message
        case let .transcript(transcript):
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            session.draft = session.draft.isEmpty ? text : "\(session.draft)\n\n\(text)"
        }
    }
}
