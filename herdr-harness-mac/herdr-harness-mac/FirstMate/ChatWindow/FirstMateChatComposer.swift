import SwiftUI
import UniformTypeIdentifiers

/// The chat window's composer: a 22 pt pill with ＋ (attach), the draft, and a
/// mic that becomes send once there is something to send. Hold the mic 300 ms
/// to talk; letting go transcribes and sends with the dictation note. Typing
/// `@` opens the tag picker above the pill.
///
/// On My First Mate there is no feature to send to: the text becomes the goal
/// of the new-feature flow instead.
struct FirstMateChatComposer: View {
    enum Mode: Equatable {
        case lead
        case feature(FirstMateFleetFeatureID)
    }

    let mode: Mode
    let session: FirstMateChatWindowSession
    let model: HerdrAppModel
    /// The selected feature's window store; nil on My First Mate.
    let store: FirstMateStore?
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    /// Tags picked from the `@` picker for this draft.
    @Binding var picks: [FirstMateMentionCandidate]
    let placeholder: String
    let suggestions: [String]
    let features: [FirstMateConversation]
    let crew: [FirstMateAssignment]
    let crewTitle: String?
    var canSend = true

    @State private var voice = HerdrQuickVoiceCapture()
    @State private var holdTask: Task<Void, Never>?
    @State private var isPressingMic = false
    /// Whether the 300 ms hold fired during this press, so letting go after
    /// Esc cancelled it is not mistaken for a quick tap.
    @State private var listenedThisPress = false
    @State private var hint: Hint = .idle
    @State private var hintTask: Task<Void, Never>?
    @State private var highlighted = 0
    /// The `@` (by offset) whose picker was closed with Esc or a pick.
    @State private var dismissedTrigger: Int?
    @State private var showsImporter = false
    @State private var editorTarget = ComposerEditorTarget()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let holdDelay: Duration = .milliseconds(300)
    static let buttonSize: CGFloat = 34

    enum Hint: Equatable {
        case idle, tapHint, listening, transcribing, nothingHeard
        case error(String)
    }

    enum MicRelease: Equatable {
        /// Transcribe and send.
        case finish
        /// The hold never fired: explain how to talk.
        case tapHint
        /// Cancelled, transcribing, or otherwise busy.
        case none
    }

    /// What letting go of the mic does.
    static func micRelease(isListening: Bool, isIdle: Bool, listenedThisPress: Bool) -> MicRelease {
        if isListening { return .finish }
        return isIdle && !listenedThisPress ? .tapHint : .none
    }

    // MARK: Derived

    private var isFeature: Bool { if case .feature = mode { true } else { false } }
    private var isListening: Bool { voice.phase == .recording || voice.phase == .locked }
    private var isTranscribing: Bool { voice.phase == .transcribing }
    private var isSending: Bool { store?.isSending ?? false }

    private var hasSendableContent: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || attachments.contains { $0.status == .uploaded && $0.uploadedPath != nil }
    }

    private var isReady: Bool {
        PromptComposerSubmission.isReady(
            draft: draft, attachments: attachments, quoteCount: 0, conversationReferenceCount: 0,
            isSubmitting: isSending, canControl: canSend, dispositionIsAvailable: true
        )
    }

    private var trigger: FirstMateMentionTrigger.Match? {
        guard let match = FirstMateMentionTrigger.match(in: draft), match.offset != dismissedTrigger else { return nil }
        return match
    }

    private var pickerOptions: [FirstMateMentionOption] {
        guard let trigger else { return [] }
        return FirstMateMentionOption.options(query: trigger.query, features: features, crew: crew)
    }

    private var pickerVisible: Bool { !pickerOptions.isEmpty && !isListening }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty, !isListening {
                FirstMateFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        FirstMateSuggestionChip(title: suggestion) { sendSuggestion(suggestion) }
                    }
                }
                .padding(.leading, 2)
                .padding(.bottom, 8)
            }
            if !attachments.isEmpty {
                ComposerAttachmentTray(attachments: attachments, retry: retryAttachment, remove: removeAttachment)
                    .padding(.bottom, 6)
            }
            pill
                .overlay(alignment: .topLeading) {
                    if pickerVisible {
                        FirstMateMentionPicker(
                            options: pickerOptions,
                            highlighted: min(highlighted, pickerOptions.count - 1),
                            crewTitle: crewTitle,
                            pick: pick,
                            hover: { highlighted = $0 }
                        )
                        .offset(y: -FirstMateMentionPicker.height(for: pickerOptions) - 2)
                        .transition(.opacity)
                    }
                }
            hintRow
        }
        .onChange(of: trigger) { _, _ in highlighted = 0 }
        .onChange(of: draft) { _, value in
            // Esc or a pick closes one `@`; typing past it keeps it closed,
            // and a new `@` opens the picker again.
            if let dismissed = dismissedTrigger, FirstMateMentionTrigger.match(in: value)?.offset != dismissed {
                dismissedTrigger = nil
            }
            if hint == .tapHint || hint == .nothingHeard { hint = .idle }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): queueAttachments(urls)
            case .failure(let error): showError(error.localizedDescription)
            }
        }
        .background {
            // Esc cancels listening wherever focus is.
            if isListening {
                Button("Cancel listening") { cancelListening() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        // The composer is rebuilt per chat, so this focuses it on every chat
        // switch; a focus request covers the sidebar's ＋ on My First Mate.
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .firstMateChatFocusComposer)) { note in
            guard (note.object as? FirstMateChatWindowSession) === session, !isListening else { return }
            focused = true
        }
        .onDisappear {
            holdTask?.cancel()
            hintTask?.cancel()
            voice.cancel()
        }
    }

    // MARK: Pill

    private var pill: some View {
        HStack(alignment: .bottom, spacing: 6) {
            roundButton(systemImage: "plus", label: "Attach files") { showsImporter = true }
                .disabled(!isFeature || !(store?.attachmentsSupported ?? false) && !(store?.isDemo ?? false) || isListening)
                .help(isFeature ? "Attach files" : "Attach files in a feature's chat")
            editor
            trailingButton
        }
        .padding(5)
        .background(HerdrTheme.inkFill(0.05), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(pillStroke, lineWidth: 1))
        .shadow(color: isListening ? HerdrTheme.alert.opacity(0.30) : focused ? HerdrTheme.accent.opacity(0.20) : .black.opacity(0.18),
                radius: isListening || focused ? 11 : 14, y: isListening || focused ? 0 : 10)
    }

    private var pillStroke: Color {
        if isListening { return HerdrTheme.alert.opacity(0.7) }
        if focused { return HerdrTheme.accent.opacity(0.65) }
        return HerdrTheme.inkFill(0.10)
    }

    @ViewBuilder private var editor: some View {
        if isListening || isTranscribing {
            HStack(spacing: 10) {
                if isListening {
                    HerdrVoiceWaveform(samples: voice.samples, isRecording: true, showsContainer: false)
                        .frame(maxWidth: 160)
                }
                Text(isListening ? "Listening…" : "Transcribing…")
                    .herdrFont(size: 13.5)
                    .foregroundStyle(isListening ? HerdrTheme.alert : HerdrTheme.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.buttonSize)
        } else {
            ComposerDraftEditor(
                placeholder: placeholder,
                text: $draft,
                maximumVisibleLines: 7,
                editorTarget: editorTarget,
                lineSpacing: 3
            )
            .herdrFont(size: 13.5)
            .foregroundStyle(HerdrTheme.primaryText)
            .focused($focused)
            .onKeyPress(.return, phases: .down, action: handleReturn)
            .onKeyPress(.upArrow, phases: .down) { _ in movePicker(by: -1) }
            .onKeyPress(.downArrow, phases: .down) { _ in movePicker(by: 1) }
            .onKeyPress(.tab, phases: .down) { _ in
                guard pickerVisible else { return .ignored }
                pickHighlighted()
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                guard pickerVisible, let trigger else { return .ignored }
                dismissedTrigger = trigger.offset
                return .handled
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, minHeight: Self.buttonSize, alignment: .leading)
            .disabled(!canSend && isFeature)
        }
    }

    @ViewBuilder private var trailingButton: some View {
        if hasSendableContent && !isListening && !isTranscribing {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .herdrFont(size: 15, weight: .bold)
                    .foregroundStyle(HerdrTheme.onPrimary)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(isReady ? HerdrTheme.accent : HerdrTheme.primaryDisabled, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.herdrPlain)
            .disabled(!isReady)
            .accessibilityLabel("Send")
            .help(isFeature ? "Send (Return)" : "Start a new feature (Return)")
        } else {
            micButton
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .herdrFont(size: 15)
            .foregroundStyle(isListening ? HerdrTheme.windowBackground : HerdrTheme.secondaryText)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background(isListening ? HerdrTheme.alert : HerdrTheme.inkFill(isPressingMic ? 0.15 : 0.08), in: .circle)
            .overlay {
                if isListening {
                    FirstMateMicPulse(reduceMotion: reduceMotion)
                }
            }
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressBegan() }
                    .onEnded { _ in pressEnded() }
            )
            .opacity(isTranscribing ? 0.5 : 1)
            .allowsHitTesting(!isTranscribing && !isSending)
            .accessibilityElement()
            .accessibilityLabel(isListening ? "Listening" : "Hold to talk")
            .accessibilityHint("Hold to record; let go to send")
            .accessibilityAddTraits(.isButton)
            .help("Hold to talk")
    }

    private func roundButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .herdrFont(size: 16, weight: .medium)
                .foregroundStyle(HerdrTheme.secondaryText)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(HerdrTheme.inkFill(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityLabel(label)
    }

    private var hintRow: some View {
        HStack(spacing: 0) {
            switch hint {
            case .idle:
                Text("Type ")
                Text("@")
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 4)
                    .background(HerdrTheme.inkFill(0.08), in: .rect(cornerRadius: 4))
                Text(isFeature ? " to tag a feature. Hold the mic to talk." : " to tag a feature. Sending starts a new feature.")
            case .tapHint:
                Text("Hold the mic to talk.")
            case .listening:
                Text("Listening. Let go to send, or press Esc to cancel.").foregroundStyle(HerdrTheme.alert)
            case .transcribing:
                Text("Transcribing…")
            case .nothingHeard:
                Text("Nothing heard.")
            case .error(let message):
                Text(message).foregroundStyle(HerdrTheme.warning)
            }
            Spacer(minLength: 0)
        }
        .herdrFont(size: 10.5)
        .foregroundStyle(HerdrTheme.tertiaryText)
        .lineLimit(1)
        .padding(.top, 7)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Keys and picker

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerReturnKeyRouter.outcome(for: press, isSkillsPaletteVisible: pickerVisible) {
        case .acceptSkill:
            pickHighlighted()
        case .insertNewline:
            ComposerNewlineInserter.insertNewline(in: $draft)
        case .send:
            send()
        }
        return .handled
    }

    private func movePicker(by delta: Int) -> KeyPress.Result {
        guard pickerVisible else { return .ignored }
        highlighted = FirstMateMentionOption.move(highlighted, by: delta, count: pickerOptions.count)
        return .handled
    }

    private func pickHighlighted() {
        let options = pickerOptions
        guard options.indices.contains(highlighted) else { return }
        pick(options[highlighted])
    }

    private func pick(_ option: FirstMateMentionOption) {
        let updated = FirstMateMentionTrigger.insert(option.candidate.name, into: draft)
        if !picks.contains(option.candidate) { picks.append(option.candidate) }
        dismissedTrigger = FirstMateMentionTrigger.match(in: updated)?.offset
        draft = updated
        focused = true
    }

    // MARK: Sending

    private func send() {
        guard isReady else { return }
        let text = draft
        let serialized = FirstMateMention.serializeComposer(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            picks: FirstMateMentionOption.picksForSend(picks, draft: text, features: features, crew: crew)
        )
        switch mode {
        case .lead:
            session.beginCreate(goal: serialized)
            draft = ""
            picks = []
        case .feature(let id):
            submit(serialized, sentDraft: text, voice: false, featureID: id)
        }
    }

    private func sendSuggestion(_ text: String) {
        guard case .feature(let id) = mode, !isSending else { return }
        submit(text, sentDraft: nil, voice: false, featureID: id, includesAttachments: false)
    }

    /// Sends through the window's store, then clears only what was sent and
    /// refreshes the main window's copy of this machine.
    private func submit(_ body: String, sentDraft: String?, voice: Bool, featureID id: FirstMateFleetFeatureID,
                        includesAttachments: Bool = true) {
        guard let store else { return }
        let context = store.operationContext
        guard context.matchesFeature(id.featureID) else { return }
        let sent = includesAttachments ? attachments.filter { $0.status == .uploaded && $0.uploadedPath != nil } : []
        let payload = PromptComposerSubmission.payload(
            draft: body, attachments: sent, quotes: [], references: [], containsDictation: voice
        )
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sentIDs = Set(sent.map(\.id))
        let session = session
        Task {
            guard await store.sendPreparedMessage(payload, expectedContext: context) else { return }
            if let sentDraft, store.composerDraft(for: context) == sentDraft {
                store.setComposerDraft("", for: context)
                picks = []
            }
            if !sentIDs.isEmpty {
                let remaining = store.composerDrafts.attachments(for: id.featureID).filter { !sentIDs.contains($0.id) }
                store.composerDrafts.setAttachments(remaining, for: id.featureID)
            }
            session.didMutate(machineID: id.machineID)
        }
    }

    // MARK: Voice

    private func pressBegan() {
        guard !isPressingMic else { return }
        isPressingMic = true
        listenedThisPress = false
        guard voice.phase == .idle else { return }
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, isPressingMic else { return }
            startListening()
        }
    }

    private func pressEnded() {
        isPressingMic = false
        holdTask?.cancel()
        holdTask = nil
        switch Self.micRelease(isListening: isListening, isIdle: voice.phase == .idle, listenedThisPress: listenedThisPress) {
        case .finish: finishListening()
        case .tapHint: showHint(.tapHint)
        case .none: break
        }
        listenedThisPress = false
    }

    private func startListening() {
        listenedThisPress = true
        hintTask?.cancel()
        hint = .listening
        voice.beginHold()
    }

    private func cancelListening() {
        voice.cancel()
        hint = .idle
    }

    /// Letting go sends, including after the recorder's own 2.65 s auto-lock:
    /// `endHold` accepts a locked recording too.
    private func finishListening() {
        hint = .transcribing
        let mode = mode
        let store = store
        Task {
            let outcome = await voice.endHold { url in try await transcribe(url, store: store) }
            switch outcome {
            case .transcript(let transcription):
                hint = .idle
                let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { showHint(.nothingHeard); return }
                switch mode {
                case .lead:
                    session.beginCreate(goal: text)
                case .feature(let id):
                    submit(text, sentDraft: nil, voice: true, featureID: id)
                }
            case .tooShort:
                showHint(.nothingHeard)
            case .failure(let message):
                showError(message)
            case .cancelled:
                hint = .idle
            }
        }
    }

    /// The same pipeline as the main First Mate screen: the companion's
    /// private transcription when preferred, else Apple's.
    private func transcribe(_ url: URL, store: FirstMateStore?) async throws -> VoiceTranscription {
        let transcriber = store ?? session.createMachineIDs.first.flatMap { session.store(for: $0) }
        if model.isDemoMode || transcriber?.isDemo == true { return try await model.transcribeVoiceNote(at: url) }
        let context = transcriber?.operationContext
        return try await VoiceTranscriptionPipeline.run(
            preferPrivate: model.preferPrivateTranscription && transcriber != nil,
            privateTranscription: {
                guard let transcriber, let context else { throw VoiceTranscriptionError.emptyTranscript }
                let response = try await transcriber.transcribeVoice(at: url, expectedContext: context)
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
    }

    private func showHint(_ value: Hint) {
        hint = value
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, hint == value else { return }
            hint = .idle
        }
    }

    private func showError(_ message: String) {
        showHint(.error(message))
    }

    // MARK: Attachments

    private func queueAttachments(_ urls: [URL]) {
        guard let store, !urls.isEmpty else { return }
        guard store.attachmentsSupported || store.isDemo else {
            showError("Update this feature's companion server to attach files.")
            return
        }
        do {
            let candidates = try urls.map { try AttachmentPolicy.candidate(for: $0, ownership: .userSelected) }
            try AttachmentPolicy.validate(existingAttachments: attachments, incomingCandidates: candidates)
            let queued = candidates.map { candidate in
                TerminalAttachment(
                    id: UUID(), filename: candidate.filename, sourceURL: candidate.sourceURL,
                    byteCount: candidate.byteCount, sourceOwnership: candidate.ownership,
                    status: .uploading, uploaded: nil, error: nil
                )
            }
            attachments.append(contentsOf: queued)
            queued.forEach(upload)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func upload(_ item: TerminalAttachment) {
        guard let store, case .feature(let id) = mode else { return }
        let context = store.operationContext
        let url = item.sourceURL
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        Task {
            do {
                let uploaded: UploadedAttachment
                if store.isDemo {
                    uploaded = UploadedAttachment(
                        id: UUID().uuidString, filename: url.lastPathComponent, originalFilename: url.lastPathComponent,
                        contentType: contentType, size: Int(item.byteCount),
                        path: "/tmp/herdr-demo-first-mate/\(url.lastPathComponent)",
                        workspaceID: "first-mate:\(id.featureID)", createdAt: ISO8601DateFormatter().string(from: .now)
                    )
                } else {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    uploaded = try await store.uploadAttachment(at: url, contentType: contentType, expectedContext: context)
                }
                let current = store.composerDrafts.attachments(for: id.featureID)
                store.composerDrafts.setAttachments(
                    PromptComposerSubmission.applyingUploadSuccess(uploaded, itemID: item.id, to: current), for: id.featureID
                )
            } catch {
                let current = store.composerDrafts.attachments(for: id.featureID)
                store.composerDrafts.setAttachments(
                    PromptComposerSubmission.applyingUploadFailure(error.localizedDescription, itemID: item.id, to: current),
                    for: id.featureID
                )
            }
        }
    }

    private func retryAttachment(_ item: TerminalAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == item.id }) else { return }
        attachments[index].error = nil
        attachments[index].status = .uploading
        upload(attachments[index])
    }

    private func removeAttachment(_ item: TerminalAttachment) {
        item.removeSourceFileIfOwned()
        attachments.removeAll { $0.id == item.id }
    }
}

/// A suggested reply above the composer. Tapping sends its text.
struct FirstMateSuggestionChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                .foregroundStyle(HerdrTheme.accent)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(hovering ? HerdrTheme.accent.opacity(0.16) : HerdrTheme.windowBackground.opacity(0.5), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(HerdrTheme.accent.opacity(0.40), lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.herdrPlain)
        .onHover { hovering = $0 }
        .accessibilityHint("Sends this reply")
    }
}

/// The ring around the mic while listening, pulsing out every 1.1 s.
private struct FirstMateMicPulse: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(HerdrTheme.alert.opacity(0.5), lineWidth: 2).padding(-5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                Circle()
                    .strokeBorder(HerdrTheme.alert.opacity(0.5), lineWidth: 2)
                    .padding(-5)
                    .scaleEffect(0.9 + 0.35 * phase)
                    .opacity(1 - phase)
            }
            .allowsHitTesting(false)
        }
    }
}

extension Notification.Name {
    /// Focuses the chat window's composer. Post it with the window's
    /// `FirstMateChatWindowSession` as the object, for example from the
    /// sidebar's ＋ after selecting My First Mate.
    static let firstMateChatFocusComposer = Notification.Name("FirstMateChatFocusComposer")
}
