import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PromptComposerView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int
    let dismissFocusRequest: Int
    let piConfiguration: PiPromptComposerConfiguration?
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isFocused: Bool
    @State private var showsTerminalKeys = false
    @State private var isShowingAttachOptions = false
    @State private var isShowingFileImporter = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingVoiceRecorder = false
    @State private var isShowingFileSearch = false
    @State private var isShowingJira = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoPreparation = ComposerPhotoPreparationState()
    @State private var photoImportTask: Task<Void, Never>?
    @State private var disposition: PiPromptDisposition = .prompt
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var isCTACapture = false
    @State private var draftContainsDictation = false
    @State private var isLockPulsing = false

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
        activateResponseAudio: ((ResponseAudioAction) -> Void)? = nil
    ) {
        self.model = model
        self.pane = pane
        self.workspace = workspace
        _draft = draft
        _attachments = attachments
        self.focusRequest = focusRequest
        self.dismissFocusRequest = dismissFocusRequest
        self.piConfiguration = piConfiguration
        self.responseAudioPlayer = responseAudioPlayer
        self.activateResponseAudio = activateResponseAudio
        _disposition = State(initialValue: piConfiguration?.preferredDisposition ?? .prompt)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activity = piConfiguration?.compactionActivity {
                PiCompactionStatusBar(activity: activity)
                    .transition(semanticControlTransition)
            } else if let piConfiguration, piConfiguration.phase == .working {
                PiPromptComposerStatusBar(
                    disposition: effectiveDisposition,
                    availableDispositions: piConfiguration.availableDispositions,
                    canSelectDisposition: piConfiguration.isConnected,
                    canAbort: piConfiguration.canAbort,
                    selectDisposition: selectDisposition,
                    stop: stopPi
                )
                    .transition(semanticControlTransition)
            }

            if let piConfiguration, showsPiOptionsBar {
                PiComposerOptionsBar(
                    configuration: piConfiguration,
                    responseAudioPlayer: responseAudioPlayer,
                    activateResponseAudio: activateResponseAudio
                )
                .padding(.top, showsPiStatusBar ? 8 : 0)
            }

            if quickVoiceCapture.phase == .locked {
                Text("recording locked · tap Voice to finish")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.alert)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(HerdrTheme.alert.opacity(0.16))
                    .clipShape(.capsule)
                    .transition(semanticControlTransition)
                    .padding(.top, showsPiStatusBar || showsPiOptionsBar ? 8 : 0)
            }

            if showsTerminalKeys {
                TerminalKeyDeck(model: model, pane: pane, isExpanded: true)
                    .transition(semanticControlTransition)
                    .padding(
                        .top,
                        showsPiStatusBar || showsPiOptionsBar || quickVoiceCapture.phase == .locked
                            ? 8
                            : 0
                    )
            }

            composerCard
                .padding(.top, composerCardTopSpacing)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsTerminalKeys)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: piConfiguration?.phase
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: piConfiguration?.compactionActivity
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: quickVoiceCapture.phase)
        .herdrHaptic(trigger: hapticPulse)
        .onAppear {
            quickVoiceCapture.onLock = {
                hapticPulse.fire(.recordingLocked)
            }
            isLockPulsing = quickVoiceCapture.phase == .locked
        }
        .onDisappear {
            cancelPhotoPreparation(clearSelection: true)
            quickVoiceCapture.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                quickVoiceCapture.cancel()
            }
        }
        .onChange(of: quickVoiceCapture.phase) { _, phase in
            isLockPulsing = phase == .locked
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
                draftContainsDictation = false
            }
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
        .onChange(of: dismissFocusRequest) {
            isFocused = false
        }
        .onChange(of: piConfiguration?.availableDispositions) { _, options in
            guard let options, !options.contains(disposition) else { return }
            disposition = options.first ?? .prompt
        }
        .onChange(of: selectedPhotos) { _, items in
            handlePhotoSelection(items)
        }
        .onChange(of: pane.id) { _, _ in
            cancelPhotoPreparation(clearSelection: true)
            showsTerminalKeys = false
        }
        .confirmationDialog("Attach", isPresented: $isShowingAttachOptions) {
            Button("Photo Library", systemImage: "photo") {
                isShowingPhotoPicker = true
            }
            Button("Files", systemImage: "folder") {
                isShowingFileImporter = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: AttachmentPolicy.maximumCount,
            matching: .images
        )
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                queueAttachments(urls, ownership: .userSelected)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isShowingVoiceRecorder) {
            HerdrVoiceNoteRecorderSheet(
                save: { url in
                    isShowingVoiceRecorder = false
                    queueAttachments([url], ownership: .appTemporary)
                },
                transcribe: { url in
                    try await model.transcribeVoiceNote(at: url)
                },
                insertTranscript: { result in
                    isShowingVoiceRecorder = false
                    appendTranscript(result.text)
                    hapticPulse.fire(.transcriptionSucceeded)
                    model.toastMessage = result.usedFallback
                        ? "Parakeet unavailable · transcribed with Apple Speech"
                        : "Transcribed with \(result.provider.rawValue)"
                },
                cancel: { isShowingVoiceRecorder = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingFileSearch) {
            WorkspaceFileSearchSheet(
                load: { query in
                    try await model.searchFiles(in: workspace, query: query)
                },
                select: { file in
                    appendToken("`\(file.path)`")
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingJira) {
            JiraTicketPickerSheet(
                loadAssigned: { try await model.fetchAssignedJiraTickets() },
                lookup: { query in try await model.fetchJiraTicket(query: query) },
                select: { ticket in
                    appendJira(ticket)
                }
            )
        }
    }

    private var showsPiStatusBar: Bool {
        piConfiguration?.compactionActivity != nil || piConfiguration?.phase == .working
    }

    private var showsPiOptionsBar: Bool {
        guard let piConfiguration else { return false }
        return piConfiguration.currentModel != nil
            || piConfiguration.capabilities.listModels
            || piConfiguration.thinkingLevel != nil
            || piConfiguration.capabilities.setThinkingLevel
            || responseAudioPlayer?.isVisible == true
    }

    private var composerCardTopSpacing: CGFloat {
        if showsTerminalKeys || quickVoiceCapture.phase == .locked { return 8 }
        if showsPiOptionsBar { return 2 }
        return showsPiStatusBar ? 8 : 0
    }

    private var semanticControlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private var composerCard: some View {
        VStack(spacing: 0) {
            if photoPreparation.isPreparing {
                photoPreparationIndicator

                Rectangle()
                    .fill(HerdrTheme.subtleSeparator)
                    .frame(height: 1)
            }

            if !attachments.isEmpty {
                ComposerAttachmentTray(
                    attachments: attachments,
                    retry: retryAttachment,
                    remove: removeAttachment
                )
                .padding(.horizontal, 9)
                .padding(.top, 9)

                Rectangle()
                    .fill(HerdrTheme.subtleSeparator)
                    .frame(height: 1)
                    .padding(.top, 7)
            }

            composerInput

            Rectangle()
                .fill(HerdrTheme.subtleSeparator)
                .frame(height: 1)

            HStack(spacing: 4) {
                ComposerAuxiliaryBar(
                    attach: { isShowingAttachOptions = true },
                    recordVoice: { isShowingVoiceRecorder = true },
                    searchFiles: { isShowingFileSearch = true },
                    chooseJira: { isShowingJira = true },
                    pasteCodeBlock: pasteCodeBlock,
                    toggleTerminalKeys: toggleTerminalKeys,
                    startLockedVoiceCapture: startLockedVoiceCapture,
                    showsTerminalKeys: showsTerminalKeys,
                    canPasteCode: !isSubmitting && canControl && !isPiCompacting,
                    canStartVoiceCapture: quickVoiceCapture.phase == .idle
                        && !isSubmitting
                        && canControl
                        && !isPiCompacting,
                    voicePhase: quickVoiceCapture.phase,
                    beginVoiceHold: beginQuickVoiceCapture,
                    endVoiceHold: finishQuickVoiceCapture,
                    finishLockedVoiceCapture: finishLockedQuickVoiceCapture
                )

                Spacer(minLength: 4)
                trailingComposerButton
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
        }
        .background(HerdrTheme.input)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(composerInputBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .shadow(
            color: quickVoiceCapture.phase == .locked
                ? HerdrTheme.alert.opacity(isLockPulsing && !reduceMotion ? 0.62 : 0.28)
                : .clear,
            radius: quickVoiceCapture.phase == .locked ? 8 : 0
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
    }

    private var photoPreparationIndicator: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.mist)

            Text(photoPreparation.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(photoPreparation.statusText)
        .accessibilityIdentifier("composer-photo-preparing")
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
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(HerdrTheme.text)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                    .disabled(isSubmitting || !canControl || isPiCompacting)
                    .accessibilityIdentifier("prompt-composer")
                    .composerLayoutMeasurement(id: "prompt-composer", label: placeholder)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
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
                    Image(systemName: effectiveDisposition.symbol)
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(HerdrTheme.ink)
            .frame(width: 34, height: 34)
            .background(isCTALockedCapture ? HerdrTheme.alert : HerdrTheme.primaryAction)
            .clipShape(.rect(cornerRadius: 8))
        }
        .frame(width: 44, height: 44)
        .contentShape(.rect)
        .scaleEffect(isCTALockedCapture && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(trailingComposerOpacity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .buttonStyle(.plain)
        .disabled(
            (isPiCompacting && !isCTALockedCapture)
                || isCTATranscribing
                || (!isCTALockedCapture && !canSend)
        )
        .accessibilityLabel(trailingComposerAccessibilityLabel)
        .accessibilityHint(trailingComposerAccessibilityHint)
        .accessibilityIdentifier("prompt-send")
        .composerLayoutMeasurement(
            id: "prompt-send",
            label: trailingComposerAccessibilityLabel
        )
    }

    private var placeholder: String {
        if let piConfiguration {
            return piConfiguration.placeholder(for: effectiveDisposition)
        }
        return pane.agentStatus == .unknown
            ? "run or type into this shell"
            : "message \(pane.displayAgentName)"
    }

    private var canControl: Bool {
        piConfiguration?.isConnected ?? model.canControl
    }

    private var isSubmitting: Bool {
        piConfiguration?.isSubmitting ?? model.isSending
    }

    private var isPiCompacting: Bool {
        piConfiguration?.isCompacting ?? false
    }

    private var sendAccessibilityHint: String {
        guard piConfiguration != nil else { return "Sends the prompt to this terminal" }
        return "Sends using \(effectiveDisposition.label.lowercased()) mode"
    }

    private var effectiveDisposition: PiPromptDisposition {
        guard let piConfiguration else { return .prompt }
        return piConfiguration.availableDispositions.contains(disposition)
            ? disposition
            : piConfiguration.preferredDisposition
    }

    private var canSend: Bool {
        let hasText = hasDraftText
        let hasAttachment = hasUploadedAttachment
        let isUploading = attachments.contains { item in
            item.status == .uploading
        }
        let dispositionIsAvailable = piConfiguration?.availableDispositions.contains(effectiveDisposition) ?? true
        return (hasText || hasAttachment)
            && !photoPreparation.blocksSending
            && !isUploading
            && !isSubmitting
            && canControl
            && dispositionIsAvailable
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUploadedAttachment: Bool {
        attachments.contains { item in
            item.status == .uploaded && item.uploadedPath != nil
        }
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
            : isFocused ? HerdrTheme.accent : HerdrTheme.surface
    }

    private var trailingComposerOpacity: Double {
        if isCTALockedCapture { return 1 }
        if isCTATranscribing { return 0.45 }
        return canSend ? 1 : 0.45
    }

    private var trailingComposerAccessibilityLabel: String {
        if isCTALockedCapture { return "Stop voice dictation" }
        if isCTATranscribing { return "Transcribing voice dictation" }
        return effectiveDisposition.label
    }

    private var trailingComposerAccessibilityHint: String {
        if isCTALockedCapture { return "Stops recording and transcribes the dictation" }
        if isCTATranscribing { return "Voice dictation is being transcribed" }
        return sendAccessibilityHint
    }

    private func appendToken(_ token: String) {
        draft = draft.isEmpty ? token : "\(draft) \(token)"
        isFocused = true
    }

    private func pasteCodeBlock() {
        guard !isSubmitting, canControl, !isPiCompacting else { return }
        if ComposerCodeBlockPaste.paste(into: $draft) {
            hapticPulse.fire(.selection)
            isFocused = true
        } else {
            model.toastMessage = "Copy some text before pasting a code block"
        }
    }

    private func toggleTerminalKeys() {
        showsTerminalKeys.toggle()
        hapticPulse.fire(showsTerminalKeys ? .controlsExpanded : .controlsCollapsed)
    }

    private func appendTranscript(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        draft = draft.isEmpty ? cleaned : "\(draft)\n\n\(cleaned)"
        draftContainsDictation = true
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

    private func startLockedVoiceCapture() {
        guard quickVoiceCapture.phase == .idle,
              !isSubmitting,
              canControl,
              !isPiCompacting
        else { return }
        isCTACapture = true
        quickVoiceCapture.beginLocked()
    }

    private func completeQuickVoiceCapture() {
        Task {
            hapticPulse.fire(.recordingStopped)
            let outcome = await quickVoiceCapture.endHold { url in
                try await model.transcribeVoiceNote(at: url)
            }
            switch outcome {
            case .cancelled:
                break
            case .tooShort:
                model.toastMessage = "Hold the mic to dictate"
            case let .transcript(result):
                appendTranscript(result.text)
                hapticPulse.fire(.transcriptionSucceeded)
                model.toastMessage = result.usedFallback
                    ? "Parakeet unavailable · transcribed with Apple Speech"
                    : "Transcribed with \(result.provider.rawValue)"
            case let .failure(message):
                hapticPulse.fire(.failed)
                model.errorMessage = message
            }
            isCTACapture = false
        }
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
        draft = draft.isEmpty ? block : "\(draft)\n\n\(block)"
        isFocused = true
    }

    private func queueAttachments(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard !urls.isEmpty else { return }
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
            model.errorMessage = error.localizedDescription
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
        Task {
            var thumbnailData = item.thumbnailData
            if thumbnailData == nil {
                thumbnailData = await Task.detached(priority: .utility) {
                    ComposerAttachmentThumbnail.encodedData(at: url)
                }.value
            }
            guard attachments.contains(where: { $0.id == item.id }) else { return }
            if let thumbnailData {
                updateAttachment(item.id) { current in
                    current.thumbnailData = thumbnailData
                }
            }

            do {
                let uploaded = try await model.uploadAttachment(
                    from: url,
                    contentType: contentType(for: url),
                    to: workspace
                )
                updateAttachment(item.id) { current in
                    current.uploaded = uploaded
                    current.error = nil
                    current.status = .uploaded
                }
                item.removeSourceFileIfOwned()
            } catch {
                updateAttachment(item.id) { current in
                    current.error = error.localizedDescription
                    current.status = .failed
                }
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

    @MainActor
    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else {
            if photoPreparation.isPreparing {
                cancelPhotoPreparation(clearSelection: false)
            }
            return
        }

        photoImportTask?.cancel()
        let token = photoPreparation.begin(photoCount: items.count)
        photoImportTask = Task { @MainActor in
            await importPhotos(items, token: token)
        }
    }

    @MainActor
    private func importPhotos(
        _ items: [PhotosPickerItem],
        token: ComposerPhotoPreparationState.Token
    ) async {
        var candidates: [AttachmentCandidate] = []
        defer { completePhotoPreparation(token) }

        do {
            try checkPhotoPreparation(token)
            try AttachmentPolicy.validateCount(
                existingCount: attachments.count,
                incomingCount: items.count
            )

            for item in items {
                try checkPhotoPreparation(token)
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw APIError.invalidResponse
                }
                try checkPhotoPreparation(token)

                let type = item.supportedContentTypes.first ?? .jpeg
                let fileExtension = type.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "herdr-photo-\(UUID().uuidString).\(fileExtension)")
                let candidate = AttachmentCandidate(
                    sourceURL: url,
                    filename: url.lastPathComponent,
                    byteCount: Int64(data.count),
                    ownership: .appTemporary
                )
                try AttachmentPolicy.validateFile(
                    named: candidate.filename,
                    byteCount: candidate.byteCount
                )
                try AttachmentPolicy.validate(
                    existingAttachments: attachments,
                    incomingCandidates: candidates + [candidate]
                )
                candidates.append(candidate)
                try data.write(to: url, options: .atomic)
                try checkPhotoPreparation(token)
            }

            try AttachmentPolicy.validate(
                existingAttachments: attachments,
                incomingCandidates: candidates
            )
            try checkPhotoPreparation(token)
            enqueue(candidates)
            candidates.removeAll()
        } catch is CancellationError {
            removeTemporarySources(
                candidates.map(\.sourceURL),
                ownership: .appTemporary
            )
        } catch {
            removeTemporarySources(
                candidates.map(\.sourceURL),
                ownership: .appTemporary
            )
            guard photoPreparation.owns(token) else { return }
            model.errorMessage = "A selected photo could not be attached: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func checkPhotoPreparation(
        _ token: ComposerPhotoPreparationState.Token
    ) throws {
        try Task.checkCancellation()
        guard photoPreparation.owns(token) else { throw CancellationError() }
    }

    @MainActor
    private func completePhotoPreparation(_ token: ComposerPhotoPreparationState.Token) {
        guard photoPreparation.finish(token) else { return }
        photoImportTask = nil
        selectedPhotos = []
    }

    @MainActor
    private func cancelPhotoPreparation(clearSelection: Bool) {
        photoImportTask?.cancel()
        photoImportTask = nil
        photoPreparation.cancel()
        if clearSelection {
            selectedPhotos = []
        }
    }

    private func removeTemporarySources(
        _ urls: [URL],
        ownership: AttachmentSourceOwnership
    ) {
        guard ownership == .appTemporary else { return }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func send() {
        guard canSend else { return }
        let originPane = pane
        let originPaneID = pane.id
        let submittedDraft = draft
        let submittedAttachments = Self.submittedAttachments(from: attachments)
        let submittedAttachmentIDs = Set(submittedAttachments.map(\.id))
        let message = Self.submissionMessage(
            draft: submittedDraft,
            uploadedPaths: submittedAttachments.compactMap(\.uploadedPath),
            containsDictation: draftContainsDictation
        )
        let piConfiguration = self.piConfiguration
        let disposition = effectiveDisposition

        Task {
            let didSend = if let piConfiguration {
                await piConfiguration.submit(message, disposition)
            } else {
                await model.sendPrompt(message, to: originPane)
            }

            if didSend {
                let clearedSubmittedDraft = model.paneDrafts.clearText(
                    for: originPaneID,
                    ifUnchanged: submittedDraft
                )
                if clearedSubmittedDraft {
                    draftContainsDictation = false
                }
                submittedAttachments.forEach { $0.removeSourceFileIfOwned() }
                attachments = Self.remainingAttachments(
                    afterRemoving: submittedAttachmentIDs,
                    from: attachments
                )
                hapticPulse.fire(.promptSent)
            } else if piConfiguration != nil {
                hapticPulse.fire(.failed)
            }
        }
    }

    static func submissionMessage(
        draft: String,
        uploadedPaths: [String],
        containsDictation: Bool
    ) -> String {
        let hasSendableText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attachmentBlock = uploadedPaths
            .map { "Attachment: `\($0)`" }
            .joined(separator: "\n")
        var message = [hasSendableText ? draft : "", attachmentBlock]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if containsDictation,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\n(transcribed audio, please account for incorrect names or typos)"
        }
        return message
    }

    static func submittedAttachments(from attachments: [TerminalAttachment]) -> [TerminalAttachment] {
        attachments.filter { $0.status == .uploaded && $0.uploadedPath != nil }
    }

    static func remainingAttachments(
        afterRemoving submittedIDs: Set<UUID>,
        from current: [TerminalAttachment]
    ) -> [TerminalAttachment] {
        current.filter { !submittedIDs.contains($0.id) }
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
