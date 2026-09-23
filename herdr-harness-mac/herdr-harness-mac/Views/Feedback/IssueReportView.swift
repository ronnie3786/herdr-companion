import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Help ▸ Report a Bug or Request a Feature… (⌘⌥F).
///
/// Collects a final title and verbatim description plus optional screenshots or
/// documents and files them as a public GitHub issue through this Mac's
/// companion or the first connected companion in the roster. An optional
/// smart-input section above the fields can draft both fields from plain
/// English, or transcribe one inline recording into the same box; neither
/// action files anything. The sheet never sends machine names, URLs or tokens;
/// the "Included details" group shows exactly what goes out.
struct IssueReportView: View {
    @Bindable var model: HerdrAppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composer = IssueReportComposer()
    @State private var smartInput: IssueReportSmartInput
    @State private var capabilityNotice: String?
    @State private var serverCapabilityList: [String] = []
    @State private var isDropTargeted = false
    @State private var isDetailsExpanded = false
    @State private var didCopyLink = false
    @State private var submitTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case smartInput
        case title
        case body
    }

    init(model: HerdrAppModel) {
        self.model = model
        #if DEBUG
        if IssueReportUITestFixture.isEnabled {
            _smartInput = State(
                initialValue: IssueReportSmartInput(capture: IssueReportUITestFixture.makeCapture())
            )
            return
        }
        #endif
        _smartInput = State(initialValue: IssueReportSmartInput())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        if let record = composer.submittedRecord {
                            successCard(record)
                        } else {
                            form
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            // ⌘V while the title field is focused; see the monitor's doc comment.
            .background(
                IssueReportPasteMonitor(
                    composer: composer,
                    isTextEditingFocused: focusedField == .body || focusedField == .smartInput,
                    isEnabled: composer.submittedRecord == nil && !composer.isSubmitting
                )
            )
            .navigationTitle("Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(composer.submittedRecord == nil ? "Cancel" : "Close") { dismiss() }
                        .disabled(composer.isSubmitting)
                        .accessibilityIdentifier("issue-report-cancel")
                }
            }
        }
        .frame(minWidth: 640, minHeight: 620)
        .interactiveDismissDisabled(composer.isSubmitting)
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            // The smart-input box and description editor keep their own text
            // paste; everywhere else ⌘V attaches the clipboard image or file.
            guard focusedField != .body, focusedField != .smartInput,
                  composer.submittedRecord == nil, !composer.isSubmitting else { return }
            composer.importItemProviders(providers)
        }
        .task {
            selectDefaultMachine()
            smartInput.attach(composer: composer)
            // The optional plain-English box is the fastest path, so it opens
            // focused; every field stays reachable with the keyboard.
            focusedField = .smartInput
        }
        .task(id: composer.machineID) {
            configureSmartInput()
            await loadCapabilities()
            await smartInput.refreshAvailability()
        }
        .onChange(of: model.machines) { _, _ in
            selectDefaultMachine()
        }
        .onChange(of: model.machineStates) { _, _ in
            selectDefaultMachine()
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
            // Cancels drafting and any capture, discards retained audio, and
            // makes every late callback a no-op for this sheet.
            smartInput.endSheet()
            composer.discardTemporaryFiles()
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Report a bug or request a feature", systemImage: "ladybug")
                .herdrFont(.title2, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)
            Text(
                "The final title and description are filed word for word as a public GitHub issue, together with any "
                    + "screenshots or documents you attach. You can also describe it in your own words under Smart "
                    + "input and let AI draft both fields — review and edit everything before filing."
            )
            .herdrFont(.body)
            .foregroundStyle(HerdrTheme.mist)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Type", selection: $composer.kind) {
                ForEach(IssueReportKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("issue-report-kind")

            if composer.machineID.isEmpty {
                Label("Connect a companion to file reports.", systemImage: "desktopcomputer")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-no-machine")
            }

            smartInputSection()

            titleField
            bodyEditor

            IssueReportAttachmentStrip(
                composer: composer,
                isDropTargeted: isDropTargeted,
                addFiles: presentOpenPanel
            )

            autofixToggle
            includedDetails
            footerNotice
            submitRow
        }
        .padding(18)
        .background(HerdrTheme.elevated.opacity(0.42))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            guard !composer.isSubmitting else { return false }
            return composer.importItemProviders(providers)
        }
        .disabled(composer.isSubmitting)
    }

    /// The optional plain-English entry point: one multiline box, one labeled
    /// AI action, and one inline microphone that glows only while it captures.
    /// No recorder sheet, waveform, timer, or playback UI is ever presented.
    private func smartInputSection() -> some View {
        @Bindable var smartInput = smartInput
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Smart input", systemImage: "sparkles")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.accent)
                Text("Optional")
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
                Spacer()
                Text("\(smartInput.source.unicodeScalars.count)/\(IssueReportDraftProfile.maxSourceCharacters)")
                    .herdrFont(.caption2, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityIdentifier("issue-report-smart-count")
            }

            Text(IssueReportSmartInputPresentation.preparationNotice(companionName: selectedMachine?.name))
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("issue-report-smart-notice")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $smartInput.source)
                    .herdrFont(size: 14, relativeTo: .body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 96)
                    .focused($focusedField, equals: .smartInput)
                    .accessibilityIdentifier("issue-report-smart-source")
                if smartInput.source.isEmpty {
                    Text("Type what you want in your own words — or dictate it — then Draft with AI.")
                        .herdrFont(size: 14, relativeTo: .body)
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.horizontal, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(HerdrTheme.input)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(focusedField == .smartInput ? HerdrTheme.accent : HerdrTheme.separator, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

            if let problem = smartInput.sourceProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-smart-source-problem")
            }

            smartInputControls
            smartInputNotices
        }
        .padding(12)
        .background(HerdrTheme.elevated.opacity(0.6))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.accent.opacity(0.25), lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("issue-report-smart-input")
    }

    /// One row when it fits, stacked when larger text or a longer companion
    /// status would otherwise clip the actions.
    private var smartInputControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                micControl
                statusIndicator
                Spacer(minLength: 8)
                restoreButton
                draftButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    micControl
                    statusIndicator
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    restoreButton
                    draftButton
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let status = IssueReportSmartInputPresentation.statusText(
            isDrafting: smartInput.isDrafting,
            voiceState: smartInput.voiceState
        ) {
            HStack(spacing: 6) {
                if smartInput.isDrafting || smartInput.voiceState == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.mist)
                }
                Text(status)
                    .herdrFont(.caption)
                    .foregroundStyle(smartInput.isRecording ? HerdrTheme.alert : HerdrTheme.mist)
                    .accessibilityIdentifier("issue-report-smart-status")
            }
        }
    }

    @ViewBuilder
    private var restoreButton: some View {
        if smartInput.canRestoreGeneratedDraft {
            Button("Restore previous", systemImage: "arrow.uturn.backward") {
                smartInput.restoreGeneratedDraft()
            }
            .accessibilityIdentifier("issue-report-smart-restore")
            .help("Put back the title and description the generated draft replaced")
        }
    }

    private var draftButton: some View {
        Button {
            smartInput.generate()
        } label: {
            Label("Draft with AI", systemImage: "sparkles")
        }
        .disabled(!smartInput.canGenerate)
        .accessibilityIdentifier("issue-report-smart-draft")
        .help("Write a title and structured description from the box above")
    }

    /// The one inline recording control. The glow is capture evidence only:
    /// a pending permission prompt shows the cancel symbol instead, and the
    /// accessible label always names the action, never the glow. Reduce Motion
    /// removes the fade; the steady glow itself is unchanged.
    private var micControl: some View {
        Button {
            smartInput.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(HerdrTheme.surface)
                if IssueReportSmartInputPresentation.isGlowing(voiceState: smartInput.voiceState) {
                    Circle()
                        .strokeBorder(HerdrTheme.alert.opacity(0.85), lineWidth: 2)
                    Circle()
                        .fill(HerdrTheme.alert.opacity(0.3))
                        .blur(radius: 5)
                }
                Image(systemName: IssueReportSmartInputPresentation.micSymbol(voiceState: smartInput.voiceState))
                    .herdrFont(size: 13, weight: .semibold)
                    .foregroundStyle(smartInput.isRecording ? HerdrTheme.alert : HerdrTheme.text)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: smartInput.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!smartInput.canToggleRecording)
        .accessibilityLabel(
            IssueReportSmartInputPresentation.micAccessibilityLabel(voiceState: smartInput.voiceState)
        )
        .accessibilityIdentifier("issue-report-smart-mic")
        .help(smartInput.isRecording ? "Stop and transcribe this recording" : "Record a description and transcribe it")
    }

    /// Recoverable failures and capability states. Errors never replace the
    /// typed source, and the AI action is disabled only when drafting itself
    /// is unsupported — manual reporting and recording keep working.
    @ViewBuilder
    private var smartInputNotices: some View {
        if let message = smartInput.draftErrorMessage {
            smartNotice(
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: HerdrTheme.alert,
                identifier: "issue-report-smart-draft-error"
            ) {
                Button("Try again") { smartInput.generate() }
                    .disabled(!smartInput.canGenerate)
                    .accessibilityIdentifier("issue-report-smart-retry")
                Button("Dismiss") { smartInput.dismissDraftError() }
                    .accessibilityIdentifier("issue-report-smart-draft-dismiss")
            }
        }
        if let message = smartInput.voiceErrorMessage {
            smartNotice(
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: HerdrTheme.alert,
                identifier: "issue-report-smart-voice-error"
            ) {
                if smartInput.canRetryTranscription {
                    Button("Retry transcription") { smartInput.retryTranscription() }
                        .disabled(smartInput.isBusy)
                        .accessibilityIdentifier("issue-report-smart-transcribe-retry")
                    Button("Discard recording") { smartInput.discardFailedRecording() }
                        .accessibilityIdentifier("issue-report-smart-discard")
                } else {
                    Button("Dismiss") { smartInput.dismissVoiceError() }
                        .accessibilityIdentifier("issue-report-smart-voice-dismiss")
                }
            }
        }
        if let message = smartInput.availability.message {
            smartNotice(
                message: message,
                symbol: "sparkles",
                tint: HerdrTheme.warning,
                identifier: "issue-report-smart-availability"
            ) {
                Button("Check again") {
                    Task { await smartInput.refreshAvailability() }
                }
                .accessibilityIdentifier("issue-report-smart-recheck")
            }
        }
    }

    private func smartNotice(
        message: String,
        symbol: String,
        tint: Color,
        identifier: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: symbol)
                .herdrFont(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                actions()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier(identifier)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Title", detail: "\(composer.titleCharacterCount)/\(IssueReportComposer.maxTitleCharacters)")
            TextField("One line that sums it up", text: $composer.title)
                .textFieldStyle(.plain)
                .herdrFont(size: 15, relativeTo: .body)
                .padding(12)
                .background(HerdrTheme.input)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(focusedField == .title ? HerdrTheme.accent : HerdrTheme.separator, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = .body }
                .accessibilityIdentifier("issue-report-title")
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Description", detail: nil)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $composer.body)
                    .herdrFont(size: 14, relativeTo: .body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .focused($focusedField, equals: .body)
                    .accessibilityIdentifier("issue-report-body")
                if composer.body.isEmpty {
                    Text("Describe what happened or what you'd like. Sent exactly as written.")
                        .herdrFont(size: 14, relativeTo: .body)
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.horizontal, 13)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(HerdrTheme.input)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(focusedField == .body ? HerdrTheme.accent : HerdrTheme.separator, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            if let problem = composer.descriptionProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-body-problem")
            }
        }
    }

    private var autofixToggle: some View {
        Toggle(isOn: $composer.autofix) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start the automated fix pipeline")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.text)
                Text("Adds the herdr-autofix label so Code Factory can plan, implement, review and release a fix.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(HerdrTheme.controlAccent)
        .accessibilityIdentifier("issue-report-autofix")
    }

    private var includedDetails: some View {
        DisclosureGroup(isExpanded: $isDetailsExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(environmentDetails.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.key)
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(HerdrTheme.mist)
                            .frame(width: 150, alignment: .leading)
                        Text(entry.value.isEmpty ? "—" : entry.value)
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
            .accessibilityIdentifier("issue-report-details-list")
        } label: {
            Text("Included details")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.muted)
        }
        .accessibilityIdentifier("issue-report-details")
    }

    private var footerNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !composer.machineID.isEmpty {
                Label(publicNoticeText, systemImage: "globe")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-notice")
            }
            if let capabilityNotice {
                Label(capabilityNotice, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-capability-notice")
            }
        }
    }

    private var submitRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = composer.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.alert)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.alert.opacity(0.1))
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                    .accessibilityIdentifier("issue-report-error")
            }
            HStack(spacing: 12) {
                Spacer()
                if composer.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.accent)
                    Text("Filing…")
                        .herdrFont(.subheadline)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Button(composer.failureMessage == nil ? "File report" : "Try again", systemImage: "paperplane.fill") {
                    submit()
                }
                .herdrProminentButton()
                .disabled(!composer.canSubmit || composer.capabilities?.available == false)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("issue-report-submit")
            }
        }
    }

    private func successCard(_ record: IssueReportRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Issue #\(record.issueNumber)", systemImage: "checkmark.circle.fill")
                .herdrFont(.title3, weight: .semibold)
                .foregroundStyle(HerdrTheme.success)
                .accessibilityIdentifier("issue-report-success-title")
            if !record.title.isEmpty {
                Text(record.title)
                    .herdrFont(.headline)
                    .foregroundStyle(HerdrTheme.text)
                    .textSelection(.enabled)
            }
            Text(record.issueUrl)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .textSelection(.enabled)
                .accessibilityIdentifier("issue-report-success-url")
            if record.autofix {
                Label("Labelled herdr-autofix — Code Factory will pick it up.", systemImage: "gearshape.2")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            if !record.attachments.isEmpty {
                Label(
                    "\(record.attachments.count) attachment\(record.attachments.count == 1 ? "" : "s") uploaded.",
                    systemImage: "paperclip"
                )
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            }
            HStack(spacing: 10) {
                Button("Open on GitHub", systemImage: "arrow.up.right.square") {
                    openOnGitHub(record)
                }
                .herdrProminentButton()
                .accessibilityIdentifier("issue-report-open")

                Button(didCopyLink ? "Copied" : "Copy link", systemImage: didCopyLink ? "checkmark" : "doc.on.doc") {
                    copyLink(record)
                }
                .accessibilityIdentifier("issue-report-copy-link")

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("issue-report-done")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.elevated.opacity(0.42))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.success.opacity(0.4), lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .accessibilityIdentifier("issue-report-success")
    }

    private func fieldLabel(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.muted)
            Spacer()
            if let detail {
                Text(detail)
                    .herdrFont(.caption2, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
    }

    // MARK: - Derived values

    private var publicNoticeText: String {
        let repository = composer.capabilities?.repository.flatMap { $0.isEmpty ? nil : $0 }
            ?? "the configured repository"
        let machineName = selectedMachine?.name ?? "this Mac's companion"
        return "Filed through \(machineName) as a public GitHub issue in \(repository). Attachments are uploaded to that repository too; "
            + "location and camera metadata are removed from photos first."
    }

    private var selectedMachine: HerdrMachine? {
        model.machines.first { $0.id == composer.machineID }
    }

    private var environmentDetails: [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return IssueReportComposer.environmentDetails(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            machineRole: selectedMachine?.role,
            serverCapabilities: serverCapabilityList
        )
    }

    // MARK: - Actions

    private func selectDefaultMachine() {
        composer.machineID = IssueReportComposer.defaultMachineID(
            machines: model.machines,
            isConnected: { machineID in
                let state = model.connectionState(forMachine: machineID)
                return state == .live || state == .demo
            },
            canControl: { model.canControl(machineID: $0) }
        ) ?? ""
    }

    /// Binds the smart input to the exact selected companion. A live run uses
    /// that companion's drafting service and quick-voice transcription; a
    /// DEBUG UI fixture substitutes deterministic, microphone-free doubles.
    private func configureSmartInput() {
        let machineID = composer.machineID
        #if DEBUG
        if IssueReportUITestFixture.isEnabled {
            smartInput.configure(
                machineID: machineID,
                service: IssueReportUITestFixture.makeDrafting(),
                transcriber: IssueReportUITestFixture.makeTranscriber()
            )
            return
        }
        #endif
        let model = self.model
        smartInput.configure(
            machineID: machineID,
            service: model.issueReportDraftService(machineID: machineID),
            transcriber: { url, machineID in
                try await model.transcribeQuickVoice(at: url, machineID: machineID)
            }
        )
    }

    private func submit() {
        guard composer.canSubmit, submitTask == nil else { return }
        let environment = environmentDetails
        submitTask = Task {
            await composer.submit(environment: environment) { request, machineID in
                try await model.submitIssueReport(request, machineID: machineID)
            }
            submitTask = nil
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = IssueReportComposer.allowedContentTypes
        panel.prompt = "Attach"
        panel.message = "Attach screenshots, logs or documents — up to "
            + "\(composer.effectiveMaxAttachments) files, "
            + "\(composer.effectiveMaxAttachmentBytes.formatted(.byteCount(style: .file))) each."
        panel.begin { response in
            guard response == .OK else { return }
            composer.addAttachments(panel.urls)
        }
    }

    private func openOnGitHub(_ record: IssueReportRecord) {
        guard let url = URL(string: record.issueUrl), url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyLink(_ record: IssueReportRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.issueUrl, forType: .string)
        didCopyLink = true
    }

    private func loadCapabilities() async {
        composer.capabilities = nil
        capabilityNotice = nil
        serverCapabilityList = []
        let machineID = composer.machineID
        guard !machineID.isEmpty else { return }
        do {
            let capabilities = try await model.issueReportCapabilities(machineID: machineID)
            guard machineID == composer.machineID else { return }
            composer.capabilities = capabilities
            if !capabilities.available {
                capabilityNotice = capabilities.reason
                    ?? "Reports aren't configured on this machine's companion server yet."
            }
        } catch {
            guard machineID == composer.machineID else { return }
            // An older companion that cannot draft still accepts manual
            // reporting; only the unsupported optional action is called out.
            capabilityNotice = Self.capabilityNotice(for: error)
        }
        let list = await fetchServerCapabilityList(machineID: machineID)
        if machineID == composer.machineID {
            serverCapabilityList = list
        }
    }

    /// The `server_capabilities` environment detail. Read through a
    /// short-lived client because the app model does not cache the list.
    private func fetchServerCapabilityList(machineID: String) async -> [String] {
        guard !model.isDemoMode,
              let configuration = model.firstMateConfiguration(machineID: machineID) else { return [] }
        let client = HerdrAPIClient(configuration: configuration)
        return (try? await client.serverCapabilities())?.capabilities ?? []
    }

    private static func capabilityNotice(for error: any Error) -> String {
        if let apiError = error as? APIError, case let .server(status, message) = apiError {
            if status == 404 || status == 426 {
                return "This machine's companion server doesn't support reports yet. "
                    + "Update the companion server to file bug reports and feature requests from the app."
            }
            if !message.isEmpty {
                return message
            }
        }
        return "Couldn't reach this machine's companion server to check report settings. You can still try to file the report."
    }
}
