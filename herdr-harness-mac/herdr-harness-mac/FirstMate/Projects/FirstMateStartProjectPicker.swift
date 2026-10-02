import SwiftUI

struct FirstMateStartProjectPicker: View {
    @Bindable var index: FirstMateProjectIndex
    let selection: FirstMateProjectSelection?
    let choose: (FirstMateProjectSelection) -> Void
    let create: () -> Void
    @State private var isPresentingProjects = false
    @State private var search = ""
    @State private var highlightedProject: FirstMateProjectSelection?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale
    private var palette: FirstMatePalette { .init(scheme: scheme) }
    private var selectedChoice: FirstMateProjectChoice? { index.choice(selection) }
    private var filteredChoices: [FirstMateProjectChoice] {
        index.activeChoices.filter { choice in
            search.isEmpty || choice.project.name.localizedCaseInsensitiveContains(search)
                || choice.host.machineName.localizedCaseInsensitiveContains(search)
                || choice.project.cwd.localizedCaseInsensitiveContains(search)
        }
    }
    private var selectionDescription: String {
        guard let choice = selectedChoice else { return "No project selected" }
        return "\(choice.project.name), \(choice.host.machineName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            projectMenu
            selectionDetails
        }
    }

    private var header: some View {
        HStack {
            Text("Project").herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
            Spacer()
            Button("New project", systemImage: "plus", action: create)
                .buttonStyle(.herdrPlain).foregroundStyle(palette.accent)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .disabled(index.hosts.isEmpty)
                .accessibilityIdentifier("first-mate-start-new-project")
        }
    }

    private var projectMenu: some View {
        Button(action: showProjects) {
            menuLabel
        }
        .buttonStyle(.herdrPlain)
        .popover(isPresented: $isPresentingProjects, arrowEdge: .bottom) { projectPopover }
        .accessibilityLabel("Choose a project")
        .accessibilityValue(selectionDescription)
        .accessibilityHint("Show available projects and their machines")
        .accessibilityIdentifier("first-mate-start-project-picker")
    }

    private var projectPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find a project, machine, or folder", text: $search)
                .textFieldStyle(.roundedBorder)
                .herdrFont(.body)
                .focused($searchFocused)
                .onSubmit(chooseHighlightedProject)
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .padding(12)
                .accessibilityLabel("Find a project, machine, or folder")
                .accessibilityIdentifier("first-mate-project-picker-search")
            projectList
            Divider()
            Button("New project…", systemImage: "plus", action: createFromPopover)
                .buttonStyle(HerdrButtonStyle(kind: .ghost))
                .disabled(index.hosts.isEmpty)
                .padding(12)
        }
        .frame(width: 440 * min(fontScale.rawValue, 1.3))
        .background(palette.background)
        .foregroundStyle(palette.text)
        .onAppear { searchFocused = true }
        .onChange(of: search) { highlightedProject = filteredChoices.first?.id }
        .onExitCommand { isPresentingProjects = false }
        .accessibilityIdentifier("first-mate-project-picker-popover")
    }

    @ViewBuilder
    private var projectList: some View {
        if filteredChoices.isEmpty {
            ContentUnavailableView(
                search.isEmpty ? "No saved projects yet" : "No matching projects",
                systemImage: "folder",
                description: Text(search.isEmpty ? "Create a project to save a machine and folder." : "Try another project name, machine, or folder.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            List(selection: $highlightedProject) {
                ForEach(filteredChoices) { choice in
                    projectButton(choice)
                        .tag(choice.id)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(min(Double(filteredChoices.count) * 84 * fontScale.rawValue, 360)))
            .onKeyPress(.return) { chooseHighlightedProject(); return .handled }
            .accessibilityLabel("Projects")
        }
    }

    private func projectButton(_ choice: FirstMateProjectChoice) -> some View {
        Button { select(choice.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: choice.id == selection ? "checkmark.circle.fill" : "folder")
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.project.name).herdrFont(.body, weight: .semibold).lineLimit(2)
                    Text("\(choice.host.machineName) · \(choice.host.availabilityLabel)")
                        .herdrFont(.callout).foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                    Text(choice.project.cwd)
                        .herdrFont(.callout, monospaced: true).foregroundStyle(palette.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.herdrPlain)
        .help(choice.project.cwd)
        .accessibilityLabel("\(choice.project.name) on \(choice.host.machineName)")
        .accessibilityValue(choice.host.availabilityLabel)
        .accessibilityIdentifier("first-mate-project-choice-\(choice.id.machineID)-\(choice.id.projectID)")
    }

    private var menuLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").herdrFont(size: 18).foregroundStyle(palette.accent)
                .frame(width: 36, height: 36)
                .background(palette.accent.opacity(0.08), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedChoice?.project.name ?? "Choose a project")
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                Text(selectedChoice?.host.machineName ?? "Save a machine and folder once")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .foregroundStyle(palette.secondaryText).accessibilityHidden(true)
        }
        .padding(14).background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line))
        .contentShape(.rect)
    }

    @ViewBuilder
    private var selectionDetails: some View {
        if let choice = selectedChoice {
            locationDetails(choice)
        } else if index.activeChoices.isEmpty {
            emptyState
        }
    }

    private func locationDetails(_ choice: FirstMateProjectChoice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Label(choice.project.cwd, systemImage: "folder")
                .textSelection(.enabled).lineLimit(3).help(choice.project.cwd)
            Spacer(minLength: 8)
            Label(choice.host.availabilityLabel, systemImage: choice.host.canManageProjects ? "checkmark.circle" : "exclamationmark.circle")
                .fixedSize()
        }
        .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(palette.secondaryText)
    }

    @ViewBuilder
    private var emptyState: some View {
        if index.isRefreshing {
            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Loading projects…") }
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(palette.secondaryText)
        } else {
            Text("Create your first project, or use Manual setup for a single session.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(palette.secondaryText)
            ForEach(index.hosts.filter { $0.error != nil || !$0.supportsProjects }) { host in
                FirstMateProjectHostNotice(host: host)
            }
        }
    }

    private func showProjects() {
        search = ""
        highlightedProject = selection ?? index.activeChoices.first?.id
        isPresentingProjects = true
    }

    private func select(_ project: FirstMateProjectSelection) {
        isPresentingProjects = false
        choose(project)
    }

    private func chooseHighlightedProject() {
        guard let choice = filteredChoices.first(where: { $0.id == highlightedProject }) else { return }
        select(choice.id)
    }

    private func moveHighlight(by offset: Int) {
        let choices = filteredChoices
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex(where: { $0.id == highlightedProject }) ?? (offset > 0 ? -1 : choices.count)
        highlightedProject = choices[min(max(current + offset, 0), choices.count - 1)].id
    }

    private func createFromPopover() {
        isPresentingProjects = false
        create()
    }
}
