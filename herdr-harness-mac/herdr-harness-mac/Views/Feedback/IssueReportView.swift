import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Help ▸ Report a Bug or Request a Feature… (⌘⌥F).
///
/// Collects a verbatim note plus optional screenshots or documents and files
/// them as a public GitHub issue through the selected machine's companion
/// server. The sheet never sends machine names, URLs or tokens; the
/// "Included details" group shows exactly what goes out.
struct IssueReportView: View {
    @Bindable var model: HerdrAppModel

    @Environment(\.dismiss) private var dismiss
    @State private var composer = IssueReportComposer()
    @State private var serverCapabilityList: [String] = []
    @State private var isDropTargeted = false
    @State private var isDetailsExpanded = false
    @State private var didCopyLink = false
    @State private var submitTask: Task<Void, Never>?
    @State private var discoveryTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case body
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
                    isBodyFocused: focusedField == .body,
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
            // The description editor keeps its own paste; everywhere else ⌘V
            // attaches the clipboard image or file.
            guard focusedField != .body, composer.submittedRecord == nil, !composer.isSubmitting else { return }
            composer.importItemProviders(providers)
        }
        .task {
            focusedField = .title
            startDiscovery()
        }
        .task(id: composer.machineID) {
            await loadServerCapabilities()
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
            discoveryTask?.cancel()
            discoveryTask = nil
            composer.discardTemporaryFiles()
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Report a bug or request a feature", systemImage: "ladybug")
                .herdrFont(.title2, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)
            Text("Your note is filed word for word as a GitHub issue, together with any screenshots or documents you attach.")
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

            if composer.showsMachinePicker {
                Picker("File through", selection: $composer.machineID) {
                    ForEach(composer.pairedMachines) { machine in
                        Text(machinePickerTitle(machine)).tag(machine.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("issue-report-machine")
                .disabled(composer.isDiscoveringReports)
            }

            if let reason = composer.selectedMachineReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-machine-reason")
            }

            if composer.pairedMachines.isEmpty && composer.hasRunDiscovery {
                // Zero paired machines. Nothing can file the report, so say so
                // instead of greying out the button.
                Label("Add a machine in Settings ▸ Machines to file reports through its companion server.", systemImage: "desktopcomputer")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("issue-report-no-machine")
            }

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
        Label(publicNoticeText, systemImage: "globe")
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("issue-report-notice")
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
            if let explanation = composer.noAvailableMachineExplanation {
                noAvailableMachinesCard(explanation)
            } else {
                submissionControls
            }
        }
    }

    /// Shown in place of the submit controls only after a sweep has finished
    /// with no available companion. The draft stays editable and "Check
    /// again" retries without discarding it.
    private func noAvailableMachinesCard(_ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(explanation, systemImage: "exclamationmark.triangle.fill")
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("issue-report-no-available")
            Link("Code Factory setup instructions", destination: IssueReportComposer.codeFactoryDocsURL)
                .herdrFont(.caption)
                .accessibilityIdentifier("issue-report-docs-link")
            HStack(spacing: 12) {
                Spacer()
                recheckButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.warning.opacity(0.1))
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    /// Asks every connected companion for its report settings again without
    /// touching the draft. Kept outside the no-available card so it stays
    /// reachable whenever an unavailable companion is selected among available
    /// ones, and while a sweep runs, where it supersedes that sweep.
    private var recheckButton: some View {
        Button("Check again", systemImage: "arrow.clockwise") {
            startDiscovery()
        }
        .disabled(composer.isSubmitting)
        .accessibilityIdentifier("issue-report-check-again")
    }

    private var submissionControls: some View {
        HStack(spacing: 12) {
            Spacer()
            if composer.canCheckAgain {
                recheckButton
            }
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
            .disabled(!composer.canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("issue-report-submit")
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
        return "Filed as a public GitHub issue in \(repository). Attachments are uploaded to that repository too; "
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

    private func submit() {
        guard submitTask == nil else { return }
        // The refresh can invalidate the cached answer or replace a removed
        // companion with another available one. In both cases this click must
        // not file through a destination the user has not seen:
        // `prepareSubmission` stops the attempt and leaves the updated machine
        // and repository notice on screen for an explicit second submission.
        guard composer.prepareSubmission(machines: model.machines, connectedIDs: connectedMachineIDs()) else { return }
        let environment = environmentDetails
        submitTask = Task {
            await composer.submit(environment: environment) { request, machineID in
                try await model.submitIssueReport(request, machineID: machineID)
            }
            submitTask = nil
        }
    }

    private func machinePickerTitle(_ machine: HerdrMachine) -> String {
        guard let label = composer.machineStatusLabel(for: machine.id) else { return machine.name }
        return "\(machine.name) — \(label)"
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

    // MARK: - Discovery

    private func connectedMachineIDs() -> Set<String> {
        IssueReportComposer.connectedMachineIDs(
            machines: model.machines,
            isDemoMode: model.isDemoMode,
            connectionState: { model.connectionState(forMachine: $0) }
        )
    }

    private func discoverMachines() async {
        let model = self.model
        let machines = model.machines
        let connectedIDs = connectedMachineIDs()
        await composer.discover(
            machines: machines,
            connectedIDs: connectedIDs
        ) { [model] machineID in
            try await model.issueReportCapabilities(machineID: machineID)
        }
    }

    private func startDiscovery() {
        guard !composer.isSubmitting else { return }
        discoveryTask?.cancel()
        discoveryTask = Task { await discoverMachines() }
    }

    /// The `server_capabilities` environment detail for the selected machine.
    /// Cleared and reloaded whenever the selection changes, and a slow answer
    /// for a previous selection is discarded.
    private func loadServerCapabilities() async {
        serverCapabilityList = []
        let machineID = composer.machineID
        guard !machineID.isEmpty else { return }
        let list = await fetchServerCapabilityList(machineID: machineID)
        guard machineID == composer.machineID else { return }
        serverCapabilityList = list
    }

    /// Read through a short-lived client because the app model does not cache
    /// the list.
    private func fetchServerCapabilityList(machineID: String) async -> [String] {
        guard !model.isDemoMode,
              let configuration = model.firstMateConfiguration(machineID: machineID) else { return [] }
        let client = HerdrAPIClient(configuration: configuration)
        return (try? await client.serverCapabilities())?.capabilities ?? []
    }
}
