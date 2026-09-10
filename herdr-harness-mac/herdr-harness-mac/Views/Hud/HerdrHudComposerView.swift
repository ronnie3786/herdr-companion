import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudComposerView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession

    @FocusState private var isComposerFocused: Bool
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var voiceErrorMessage: String?
    @State private var isShowingFilePicker = false
    @Environment(\.herdrFontScale) private var fontScale
    @State private var composerWidth: CGFloat = .infinity

    /// A submission clears validation within a turn or two; the ceiling only
    /// exists so a failed submit cannot leave this polling forever.
    private static let runStartPollInterval = Duration.milliseconds(40)
    private static let runStartPollAttempts = 25

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                HerdrHudModelChip(
                    currentSelectionID: session.selectedModel,
                    availableModels: session.availableModels,
                    defaultModel: session.defaultModel,
                    isLoading: session.isLoadingModels,
                    errorMessage: session.modelsError,
                    favorites: session.modelFavorites,
                    selectModel: { session.setSelectedModel($0) },
                    retry: { Task { await session.loadModels(model: model) } }
                )
                PiThinkingLevelChip(
                    currentLevel: session.selectedThinkingLevel.rawValue,
                    isSetting: false,
                    isEnabled: true,
                    isInteractive: true,
                    selectLevel: { session.selectedThinkingLevel = $0 }
                )
                .accessibilityIdentifier("hud-thinking")
                .help("Thinking level for the next HUD prompt")
                .layoutPriority(1)
                Spacer(minLength: 4)
                if let thread = session.thread {
                    Text("Thread · \(thread.turnCount) turns")
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.muted)
                        .lineLimit(1)
                }
            }
            if !session.pendingAttachments.isEmpty || !session.pendingQuotes.isEmpty {
                attachmentChips
            }
            if let voiceErrorMessage, !voiceErrorMessage.isEmpty {
                Text(voiceErrorMessage)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 0) {
                composerInput
                composerActionsLayout {
                    HStack(spacing: 2) {
                        Button {
                            isShowingFilePicker = true
                        } label: {
                            Label("Attach", systemImage: "paperclip")
                                .frame(minHeight: HerdrTheme.minHitTarget)
                                .padding(.horizontal, 6)
                        }
                        .help("Attach files to this prompt")
                        .accessibilityLabel("Attach file")
                        .accessibilityIdentifier("hud-attach-file")

                        Button(action: pasteCodeBlock) {
                            Label("Paste code", systemImage: "chevron.left.forwardslash.chevron.right")
                                .frame(minHeight: HerdrTheme.minHitTarget)
                                .padding(.horizontal, 6)
                        }
                        .help("Append clipboard as a fenced code block (⌘⇧V in the prompt)")
                        .accessibilityLabel("Paste code block")
                        .accessibilityIdentifier("hud-code-block-paste")

                        Button(action: toggleVoiceCapture) {
                            Label(isVoiceCaptureActive ? "Finish" : "Voice", systemImage: isVoiceCaptureActive ? "stop.fill" : "mic")
                                .frame(minHeight: HerdrTheme.minHitTarget)
                                .padding(.horizontal, 6)
                        }
                        .foregroundStyle(isVoiceCaptureActive ? HerdrTheme.alert : HerdrTheme.mist)
                        .disabled(quickVoiceCapture.phase == .transcribing)
                        .help(voiceCaptureAccessibilityLabel)
                        .accessibilityLabel(voiceCaptureAccessibilityLabel)
                        .accessibilityIdentifier("hud-mic")
                    }
                    .buttonStyle(.plain)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 0) {
                        Spacer(minLength: 4)
                        Button(action: submit) {
                            Image(systemName: "arrow.up")
                                .herdrFont(.headline, weight: .semibold)
                                .foregroundStyle(HerdrTheme.ink)
                                .frame(width: 30, height: 30)
                                .background(HerdrTheme.primaryAction, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                                .opacity(canSubmit ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .help("Send prompt. Return sends; modified Return inserts a new line.")
                        .accessibilityLabel("Send HUD prompt")
                        .accessibilityIdentifier("hud-send")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
            .background(HerdrTheme.input, in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isComposerFocused ? HerdrTheme.accent : HerdrTheme.separator, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: 9))
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            composerWidth = width
        }
        .padding(.horizontal, 17)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(HerdrTheme.graphite)
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

    private func pasteCodeBlock() {
        if !ComposerCodeBlockPaste.paste(into: &session.draft) {
            session.reportAttachmentError("Copy some text before pasting a code block.")
        }
        isComposerFocused = true
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
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                ComposerDraftEditor(
                    placeholder: session.thread == nil ? "Ask anything, or tell it what to do…" : "Reply to this thread…",
                    text: $session.draft,
                    maximumVisibleLines: 4,
                    pasteCode: pasteCodeBlock
                )
                    .herdrFont(size: 13)
                    .foregroundStyle(HerdrTheme.text)
                    .focused($isComposerFocused)
                    .onSubmit(handleSubmit)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
                    .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
    }

    private var canSubmit: Bool {
        (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.pendingAttachments.isEmpty || !session.pendingQuotes.isEmpty) && !session.isRunning
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
        Task {
            let startedBefore = session.runStartedRevision
            let submission = Task { await session.submit(model: model) }
            // Get out of the way for the length of the run, then come back with
            // the answer. Waiting for the run to actually start keeps a
            // validation failure — which never starts one — on screen.
            let didCollapse = await collapseOnceRunning(startedBefore: startedBefore)
            await submission.value
            if didCollapse { controller.endRunAutoCollapse() }
        }
    }

    private func collapseOnceRunning(startedBefore: Int) async -> Bool {
        for _ in 0..<Self.runStartPollAttempts {
            if session.runStartedRevision != startedBefore {
                return controller.beginRunAutoCollapse()
            }
            try? await Task.sleep(for: Self.runStartPollInterval)
        }
        return false
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
