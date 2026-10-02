import AppKit
import SwiftUI

struct AgentRoleSourcesSheet: View {
    let catalog: any AgentRoleSkillCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var sourceName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Skills from this Mac").herdrFont(.title2, weight: .semibold)
                Text("Choose folders containing Pi skills. Saving a role copies its selected skill packages, including supporting files, to the computer where it runs.")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Text("Folders and access permissions stay on this Mac. After changing local files, use Update Copies on the role's Skills tab to refresh its saved packages.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(catalog.sources) { source in
                        let skillCount = catalog.skills.count { $0.source == source.id }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Label(source.name, systemImage: source.available ? "folder" : "folder.badge.questionmark")
                                    .herdrFont(.headline)
                                Spacer()
                                if !source.available {
                                    Button("Grant Access…") { chooseFolder(replacing: source) }
                                }
                                Button("Remove folder", systemImage: "minus.circle") { remove(source) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(source.name) folder")
                            }
                            Text(source.path).herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(source.available
                                ? "\(skillCount) \(skillCount == 1 ? "skill" : "skills")"
                                : "Unavailable. Choose this folder to grant access, or add another folder.")
                                .herdrFont(.caption)
                                .foregroundStyle(source.available ? HerdrTheme.secondaryText : HerdrTheme.warning)
                        }
                        .padding(12)
                        .background(HerdrTheme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if catalog.sources.isEmpty {
                        Text("No skill folders. Add a folder to browse its skills.")
                            .foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("Source label (optional)", text: $sourceName)
                    .textFieldStyle(.roundedBorder)
                Button("Add Folder…", systemImage: "folder.badge.plus") { chooseFolder(replacing: nil) }
            }
            if let error = errorMessage ?? catalog.errorMessage {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
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
        .frame(width: 580, height: 540)
        .background(HerdrBackground())
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("agent-role-sources-sheet")
    }

    private func chooseFolder(replacing source: AgentRoleSkillSource?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a skill folder"
        panel.message = "Choose a folder containing SKILL.md files and their supporting resources."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use Folder"
        if let source { panel.directoryURL = URL(fileURLWithPath: source.path, isDirectory: true) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try catalog.addSource(url, name: source?.name ?? sourceName)
                sourceName = ""
                errorMessage = nil
                Task { await catalog.refresh() }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func remove(_ source: AgentRoleSkillSource) {
        catalog.removeSource(source.id)
        Task { await catalog.refresh() }
    }
}
