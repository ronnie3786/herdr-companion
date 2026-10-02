import SwiftUI

struct FirstMateProjectsView: View {
    @Bindable var index: FirstMateProjectIndex
    var manualSetup: () -> Void = {}
    let startSession: (FirstMateProjectSelection?) -> Void
    @State private var search = ""
    @State private var showArchived = false
    @State private var editor: FirstMateProjectEditorModel?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrHostsTitleBar) private var hostsTitleBar
    private var palette: FirstMatePalette { .init(scheme: scheme) }
    private var choices: [FirstMateProjectChoice] {
        index.choices(includeArchived: showArchived).filter {
            search.isEmpty || $0.project.name.localizedCaseInsensitiveContains(search)
                || $0.project.cwd.localizedCaseInsensitiveContains(search)
                || $0.host.machineName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hostsTitleBar { FirstMateProjectPageHeader(title: "Projects", refresh: refresh) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Projects").herdrFont(size: 27, weight: .semibold).accessibilityAddTraits(.isHeader)
                            Text("A familiar place to start your next session.")
                                .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        Button("New project", systemImage: "plus", action: newProject)
                            .buttonStyle(HerdrButtonStyle(kind: .primary)).disabled(index.hosts.isEmpty)
                            .accessibilityIdentifier("first-mate-projects-new")
                    }
                    HStack {
                        TextField("Find a project", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                            .accessibilityLabel("Find a project")
                            .accessibilityIdentifier("first-mate-projects-search")
                        Spacer()
                        Toggle("Show archived", isOn: $showArchived).toggleStyle(.checkbox)
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .accessibilityIdentifier("first-mate-projects-show-archived")
                    }
                    if choices.isEmpty {
                        if index.isRefreshing && !index.hasLoaded {
                            ProgressView("Loading projects…").frame(maxWidth: .infinity).padding(30)
                        } else if !search.isEmpty {
                            ContentUnavailableView.search(text: search)
                        } else {
                            ContentUnavailableView {
                                Label("Your projects start here", systemImage: "folder.badge.plus")
                            } description: {
                                Text(index.hosts.isEmpty ? "Add a companion in Settings → Connections, then choose a folder on that machine." : "Save a machine and folder once. Start a new First Mate session whenever you need one.")
                            } actions: {
                                Button("Create a project", action: newProject).buttonStyle(HerdrButtonStyle(kind: .primary)).disabled(index.hosts.isEmpty)
                                Button("Start manually", action: manualSetup)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(choices) { choice in
                                FirstMateProjectRow(choice: choice, edit: { edit(choice) }, start: { startSession(choice.id) })
                            }
                        }
                    }
                    ForEach(index.hosts.filter { $0.error != nil || ($0.hasLoaded && !$0.supportsProjects) }) { host in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(host.machineName).herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            FirstMateProjectHostNotice(host: host)
                        }
                    }
                    Label("One machine. One folder. Each session gets its own conversation.", systemImage: "folder")
                        .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(palette.secondaryText)
                        .padding(.top, 3)
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(36).frame(maxWidth: .infinity)
            }
        }
        .herdrPaneBackground(palette.background)
        .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
        .tint(palette.accent).buttonStyle(HerdrButtonStyle(kind: .outline))
        .herdrTitleBar { Text("Projects").herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold) } trailing: {
            Button("New session", systemImage: "plus") { startSession(nil) }
                .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
            Button("Refresh projects", systemImage: "arrow.clockwise", action: refresh)
                .buttonStyle(HerdrIconButtonStyle(tint: palette.iconTint))
        }
        .sheet(item: $editor) { editor in FirstMateProjectEditorView(model: editor, index: index) { _ in } }
        .accessibilityIdentifier("first-mate-projects")
    }

    private func newProject() { editor = .init() }
    private func edit(_ choice: FirstMateProjectChoice) {
        editor = .init(choice: choice, connection: index.connection(for: choice.host.machineID))
    }
    private func refresh() { Task { await index.refresh() } }
}
