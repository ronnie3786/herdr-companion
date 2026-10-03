import SwiftUI

struct FirstMateProjectEditorView: View {
    @Bindable var model: FirstMateProjectEditorModel
    @Bindable var index: FirstMateProjectIndex
    let saved: (FirstMateProjectSelection) -> Void
    @State private var browser: FirstMateFolderBrowserModel?
    @State private var archiveModel: FirstMateProjectArchiveModel?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var palette: FirstMatePalette { .init(scheme: scheme) }
    private var nameValidationMessage: String? {
        if model.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return "Use a single-line project name without control characters."
        }
        if model.name.unicodeScalars.count > 160 { return "Use a project name with 160 characters or fewer." }
        return nil
    }
    private var pathValidationMessage: String? {
        if model.cwd.contains("\0") { return "Remove the unsupported character from the folder path." }
        if model.cwd.unicodeScalars.count > 4096 { return "Use a folder path with 4,096 characters or fewer." }
        if !model.cwd.isEmpty && !model.cwd.hasPrefix("/") && model.cwd != "~" && !model.cwd.hasPrefix("~/") {
            return "Use an absolute path or ~/ for this machine’s home folder, or Browse to choose a folder."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "folder")
                    .herdrFont(size: 22).foregroundStyle(palette.accent)
                    .padding(10).background(palette.accent.opacity(0.08), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isEditing ? "Edit project" : "New project")
                        .herdrFont(size: 20, weight: .semibold).accessibilityAddTraits(.isHeader)
                    Text("Choose where your First Mate will work.")
                        .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(palette.secondaryText)
                }
                Spacer()
            }
            .padding(26)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Project name").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            TextField("e.g. iOS App", text: $model.name)
                                .textFieldStyle(.roundedBorder).focused($nameFocused)
                                .accessibilityLabel("Project name").accessibilityIdentifier("first-mate-project-name")
                            if let nameValidationMessage {
                                FirstMateProjectNotice(text: nameValidationMessage, warning: true)
                                    .accessibilityIdentifier("first-mate-project-name-validation")
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Picker("Machine", selection: $model.machineID) {
                                Text("Choose a machine").tag(nil as String?)
                                ForEach(index.hosts) { host in
                                    Text("\(host.machineName) · \(host.availabilityLabel)").tag(Optional(host.machineID))
                                }
                                if let machineID = model.machineID, index.host(machineID) == nil {
                                    Text("Machine unavailable").tag(Optional(machineID))
                                }
                            }
                            .disabled(model.isEditing).onChange(of: model.machineID) { model.changeMachine() }
                            .accessibilityIdentifier("first-mate-project-machine")
                            if model.isEditing {
                                Text("Create a separate project to use another machine.")
                                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.secondaryText)
                            }
                            FirstMateProjectHostNotice(host: index.host(model.machineID))
                            if model.isEditing && index.host(model.machineID) == nil {
                                FirstMateProjectNotice(text: "This project’s machine is no longer configured. Reconnect it in Settings → Connections to make changes.", warning: true)
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Project folder").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            HStack(spacing: 8) {
                                TextField("Path on the selected machine", text: $model.cwd)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Project folder on the selected machine")
                                    .accessibilityIdentifier("first-mate-project-folder")
                                Button("Browse…", action: browse)
                                    .disabled(index.host(model.machineID)?.supportsDirectoryBrowser != true || index.host(model.machineID)?.canManageProjects != true)
                                    .accessibilityIdentifier("first-mate-project-browse")
                            }
                            Text(model.isEditing ? "Existing sessions keep their original folder. New sessions will use this location." : "New sessions will start in this folder.")
                                .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.secondaryText)
                            if let pathValidationMessage {
                                FirstMateProjectNotice(text: pathValidationMessage, warning: true)
                                    .accessibilityIdentifier("first-mate-project-path-validation")
                            }
                        }
                    }
                    .disabled(model.isArchived)
                    if let error = model.error {
                        FirstMateProjectNotice(text: error, warning: true)
                    }
                    if model.isConflict {
                        Button("Reload project and replace these fields", action: reload)
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .accessibilityIdentifier("first-mate-project-reload")
                    }
                    if model.isArchived {
                        FirstMateProjectNotice(text: "This project is archived. Restore it to use it for new sessions.")
                    }
                }
                .padding(.horizontal, 26).padding(.bottom, 24)
                .disabled(model.isSaving)
            }
            HStack(spacing: 10) {
                if model.isEditing {
                    Button(model.isArchived ? "Restore project" : "Archive project", action: archive)
                        .disabled(model.isSaving || model.isConflict || index.host(model.machineID)?.canManageProjects != true)
                        .accessibilityIdentifier("first-mate-project-archive")

                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving project") }
                Button("Cancel", role: .cancel) { dismiss() }.disabled(model.isSaving)
                    .keyboardShortcut(.cancelAction)
                if !model.isArchived {
                    Button(model.isEditing ? "Save changes" : "Create project", action: save)
                        .buttonStyle(HerdrButtonStyle(kind: .primary))
                        .disabled(!model.canSave(in: index) || nameValidationMessage != nil || pathValidationMessage != nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("first-mate-project-save")
                }
            }
            .padding(18).herdrHairline(.top, color: palette.hairline)
        }
        .herdrFont(.body)
        .frame(minWidth: 540, idealWidth: 580, maxWidth: 820, minHeight: 520, idealHeight: 560, maxHeight: 800)
        .background(palette.background)
        .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
        .tint(palette.accent)
        .buttonStyle(HerdrButtonStyle(kind: .outline))
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { nameFocused = !model.isEditing }
        .sheet(item: $browser) { browser in
            FirstMateFolderBrowserView(model: browser) { model.cwd = $0 }
        }
        .sheet(item: $archiveModel) { archiveModel in
            FirstMateProjectArchiveSheet(model: archiveModel) {
                guard let selection = await model.setArchived(true, in: index) else { return false }
                saved(selection)
                dismiss()
                return true
            }
        }
        .accessibilityIdentifier("first-mate-project-editor")
    }

    private func browse() {
        guard let connection = model.connection(in: index) else { return }
        browser = .init(machineID: connection.machineID, machineName: connection.machineName, client: connection.client,
                        initialPath: model.cwd.isEmpty ? nil : model.cwd, isConnectionCurrent: { index.isCurrent(connection) })
    }
    private func save() {
        Task { if let selection = await model.save(in: index) { saved(selection); dismiss() } }
    }
    private func reload() { Task { await model.reload(in: index) } }
    private func archive() {
        if model.isArchived { Task { if let selection = await model.setArchived(false, in: index) { saved(selection); dismiss() } } }
        else if let project = model.original, let connection = model.connection(in: index) {
            archiveModel = .init(project: project, connection: connection, isCurrent: { index.isCurrent(connection) })
        }
    }
}
