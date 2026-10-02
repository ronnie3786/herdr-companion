import SwiftUI

struct AgentRoleSourcesSheet: View {
    let catalog: any AgentRoleSkillCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var sourceName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Skills from this Mac").herdrFont(.title2, weight: .semibold)
                Text("Herdr finds the usual Agent, Codex, Claude, Dox Agent, Point-Free and Pi skill folders in your user account.")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS requires one-time access to each folder. Linked skills may point to another folder that needs its own access. Only the packages you select are copied when you save a role.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(catalog.issues) { issue in
                        AgentRoleSkillIssueRow(issue: issue) { grant(issue.path) }
                    }
                    ForEach(catalog.sources) { source in
                        let skillCount = catalog.skills.count { $0.source == source.id }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Label(source.name, systemImage: source.available ? "folder" : "folder.badge.questionmark")
                                    .herdrFont(.callout, weight: .semibold)
                                Spacer()
                                if !source.available && !catalog.issues.contains(where: { $0.path == source.path && $0.needsAccess }) {
                                    Button("Choose folder…") { chooseFolder(replacing: source) }
                                }
                                Button("Remove folder", systemImage: "minus.circle") { remove(source) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(source.name) folder")
                            }
                            Text(source.path).herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if source.available {
                                Text("\(skillCount) \(skillCount == 1 ? "skill" : "skills")")
                                    .herdrFont(.caption)
                                    .foregroundStyle(HerdrTheme.secondaryText)
                            }
                        }
                        .padding(14)
                        .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.outline))
                    }
                    if !catalog.suggestedSources.isEmpty {
                        Text("Common skill folders")
                            .herdrFont(.callout, weight: .semibold)
                            .padding(.top, 8)
                        Text("Choose a folder you use to let macOS grant access. Folders that are not installed can be left alone.")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.secondaryText)
                        ForEach(catalog.suggestedSources) { source in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name).herdrFont(.callout, weight: .medium)
                                    Text(source.path).herdrFont(.caption, monospaced: true)
                                        .foregroundStyle(HerdrTheme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Button("Allow access…") { grant(source.path) }
                                    .fixedSize()
                            }
                            .padding(12)
                            .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                        }
                    }
                    if catalog.sources.isEmpty && catalog.issues.isEmpty && catalog.suggestedSources.isEmpty {
                        ContentUnavailableView("Connect your skill folders", systemImage: "folder.badge.plus",
                            description: Text("Choose one or more folders containing SKILL.md files. Their names, descriptions and supporting files stay together."))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                TextField("Folder label (optional)", text: $sourceName)
                    .textFieldStyle(.roundedBorder)
                Button("Add folders…", systemImage: "folder.badge.plus") { chooseFolder(replacing: nil) }
            }
            if let errorMessage {
                Text(errorMessage).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
                    .disabled(catalog.isLoading)
                if catalog.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 580)
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.controlAccent)
        .accessibilityIdentifier("agent-role-sources-sheet")
    }

    private func chooseFolder(replacing source: AgentRoleSkillSource?) {
        AgentRoleFolderPicker.choose(catalog: catalog, path: source?.path, name: source?.name ?? sourceName) { error in
            errorMessage = error
            if error == nil { sourceName = "" }
        }
    }

    private func grant(_ path: String) {
        AgentRoleFolderPicker.choose(catalog: catalog, path: path) { errorMessage = $0 }
    }

    private func remove(_ source: AgentRoleSkillSource) {
        catalog.removeSource(source.id)
        Task { await catalog.refresh() }
    }
}
