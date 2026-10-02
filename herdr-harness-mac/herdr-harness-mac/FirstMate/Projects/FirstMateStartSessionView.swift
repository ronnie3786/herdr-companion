import SwiftUI

struct FirstMateStartSessionView: View {
    @Bindable var model: FirstMateStartSessionModel
    @Bindable var index: FirstMateProjectIndex
    let manageProjects: () -> Void
    let started: (FirstMateStartedSession) -> Void
    @State private var projectEditor: FirstMateProjectEditorModel?
    @State private var browser: FirstMateFolderBrowserModel?
    @FocusState private var promptFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrHostsTitleBar) private var hostsTitleBar
    private var palette: FirstMatePalette { .init(scheme: scheme) }

    var body: some View {
        page
            .herdrPaneBackground(palette.background)
            .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
            .tint(palette.accent)
            .buttonStyle(HerdrButtonStyle(kind: .outline))
            .herdrTitleBar {
                Text("New First Mate session").herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
            } trailing: {
                titleBarActions
            }
            .onChange(of: model.prompt) { model.clearErrorAfterEditing() }
            .onChange(of: model.mode) { model.clearErrorAfterEditing() }
            .onChange(of: model.manualTitle) { model.clearErrorAfterEditing() }
            .onChange(of: model.manualPath) { model.clearErrorAfterEditing() }
            .sheet(item: $projectEditor) { editor in
                FirstMateProjectEditorView(model: editor, index: index, saved: chooseProject)
            }
            .sheet(item: $browser) { browser in
                FirstMateFolderBrowserView(model: browser) { model.manualPath = $0 }
            }
            .accessibilityIdentifier("first-mate-start-session")
    }

    private var page: some View {
        VStack(spacing: 0) {
            if !hostsTitleBar {
                FirstMateProjectPageHeader(title: "New First Mate session", refresh: refresh, projects: manageProjects)
                    .disabled(model.isSending)
            }
            ScrollView {
                sessionForm
            }
        }
    }

    private var sessionForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            introduction
            setupModePicker
            setupFields
            promptSection
            if index.hosts.isEmpty {
                FirstMateProjectNotice(text: "Add a companion in Settings → Connections to create projects and sessions.")
            }
            if !model.prompt.isEmpty {
                Button("Clear form", action: model.reset)
                    .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(palette.secondaryText)
            }
        }
        .disabled(model.isSending)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 30).padding(.vertical, 48)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sailboat").herdrFont(size: 34).foregroundStyle(palette.accent).accessibilityHidden(true)
            Text("What are we working on?").herdrFont(size: 27, weight: .semibold).accessibilityAddTraits(.isHeader)
            Text("Give your First Mate a place to work and a starting point.")
                .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(palette.secondaryText)
        }
    }

    private var setupModePicker: some View {
        Picker("Session setup", selection: $model.mode) {
            ForEach(FirstMateStartMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).frame(maxWidth: 265)
        .tint(HerdrTheme.controlAccent)
        .labelsHidden()
        .accessibilityLabel("Session setup")
        .accessibilityIdentifier("first-mate-start-mode")
    }

    @ViewBuilder
    private var setupFields: some View {
        if model.mode == .project {
            FirstMateStartProjectPicker(
                index: index, selection: model.selectedProject,
                choose: chooseProject, create: newProject
            )
        } else {
            FirstMateManualSetupView(model: model, index: index, browse: browse)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptComposer
            if let reason = model.unavailableReason(in: index) {
                FirstMateProjectNotice(text: reason, warning: true)
            }
            if let error = model.error {
                FirstMateProjectNotice(text: error, warning: true)
            }
            if model.needsProjectReload {
                Button("Reload project details", action: reloadProject)
            }
            Label("A Second Mate starts this session with your prompt in the selected folder.", systemImage: "sailboat")
                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Starting prompt").herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(palette.secondaryText)
            TextField("Start with a ticket, an idea, or something you want to fix…", text: $model.prompt, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(5...12)
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .focused($promptFocused)
                .accessibilityLabel("Starting prompt")
                .accessibilityIdentifier("first-mate-start-prompt")
            promptActions
        }
        .padding(17)
        .background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(promptFocused ? palette.accent : palette.line))
    }

    private var promptActions: some View {
        HStack(spacing: 12) {
            Text("⌘ Return to start").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.tertiaryText)
            Spacer()
            if model.isSending { ProgressView().controlSize(.small).accessibilityLabel("Starting session") }
            Button(action: start) {
                Label(model.isSending ? "Starting…" : "Start session", systemImage: "arrow.up")
                    .labelStyle(DashboardInlineLabelStyle(spacing: 7))
            }
            .buttonStyle(HerdrButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canStart(in: index))
            .accessibilityIdentifier("first-mate-start-submit")
        }
    }

    @ViewBuilder
    private var titleBarActions: some View {
        Button("Manage projects", systemImage: "folder", action: manageProjects)
            .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint)).disabled(model.isSending)
        Button("Refresh machines", systemImage: "arrow.clockwise", action: refresh)
            .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint)).disabled(model.isSending)
    }

    private func start() { Task { if let session = await model.start(in: index) { started(session) } } }
    private func refresh() { Task { await index.refresh() } }
    private func reloadProject() { Task { await model.reloadProject(in: index) } }
    private func chooseProject(_ selection: FirstMateProjectSelection) {
        model.chooseProject(selection)
        promptFocused = true
    }
    private func newProject() {
        projectEditor = .init(preferredMachineID: model.selectedProject?.machineID ?? model.manualMachineID)
    }
    private func browse() {
        guard let connection = index.connection(for: model.manualMachineID) else { return }
        browser = .init(machineID: connection.machineID, machineName: connection.machineName, client: connection.client,
                        initialPath: model.manualPath.isEmpty ? nil : model.manualPath, isConnectionCurrent: { index.isCurrent(connection) })
    }
}
