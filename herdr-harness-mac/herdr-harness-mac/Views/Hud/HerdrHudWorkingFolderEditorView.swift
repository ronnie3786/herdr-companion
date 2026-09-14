import SwiftUI
import UniformTypeIdentifiers

struct HerdrHudWorkingFolderEditorView: View {
    let session: HerdrHudSession
    let machine: HerdrMachine

    @State private var path = ""
    @State private var errorMessage: String?
    @State private var isChoosingFolder = false
    @Environment(\.dismiss) private var dismiss

    private var isLocalMachine: Bool {
        HerdrHudWorkingFolder.isLocalMachine(machine)
    }

    private var folderHelpText: String {
        [
            "New HUD chats start in ~. Save other folders here for this machine;",
            "existing chats keep the folder they started with."
        ].joined(separator: " ")
    }

    private var remoteFolderHelpText: String {
        [
            "Enter an absolute path on the remote machine. Herdr sends it unchanged;",
            "it is not expanded on this Mac."
        ].joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Working folders")
                        .herdrFont(.headline, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(machine.name)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text(folderHelpText)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Absolute path on this machine", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPath)
                if isLocalMachine {
                    Button("Choose", systemImage: "folder", action: chooseFolder)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Choose a folder on this Mac")
                        .accessibilityLabel("Choose a folder on this Mac")
                        .accessibilityIdentifier("hud-working-folder-choose")
                }
                Button("Add", systemImage: "plus", action: addPath)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("hud-working-folder-add")
            }

            if isLocalMachine {
                Text("Choose a folder or enter its absolute path.")
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            } else {
                Text(remoteFolderHelpText)
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hud-working-folder-error")
            }

            Divider().overlay { HerdrTheme.separator }

            Text("Saved for this machine")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)

            if session.customWorkingFolders(for: machine.id).isEmpty {
                Text("No custom folders yet.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(session.customWorkingFolders(for: machine.id)) { folder in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(HerdrTheme.accent)
                                    .accessibilityHidden(true)
                                Text(folder.displayPath(for: machine))
                                    .herdrFont(.caption)
                                    .foregroundStyle(HerdrTheme.text)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button("Remove", systemImage: "trash", action: {
                                    remove(folder)
                                })
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(HerdrTheme.muted)
                                .help("Remove this saved folder")
                                .accessibilityLabel("Remove \(folder.displayPath(for: machine))")
                                .accessibilityIdentifier("hud-working-folder-remove-\(folder.id)")
                            }
                            .frame(minHeight: HerdrTheme.minHitTarget)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .scrollIndicators(.visible)
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(HerdrTheme.graphite)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderPickerResult(result)
        }
    }

    private func chooseFolder() {
        guard isLocalMachine else { return }
        isChoosingFolder = true
    }

    private func addPath() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isLocalHome = isLocalMachine
            && HerdrHudWorkingFolder.displayPath(trimmed, for: machine) == HerdrHudWorkingFolder.homePath
        if trimmed == HerdrHudWorkingFolder.homePath || isLocalHome {
            _ = session.selectWorkingFolder(path: HerdrHudWorkingFolder.homePath, for: machine.id)
            path = ""
            errorMessage = nil
            return
        }
        do {
            let folder = try session.addCustomWorkingFolder(path: trimmed, machineID: machine.id)
            _ = session.selectWorkingFolder(path: folder.path, for: machine.id)
            path = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ folder: HerdrHudWorkingFolder) {
        _ = session.removeCustomWorkingFolder(path: folder.path, machineID: machine.id)
        errorMessage = nil
    }

    private func handleFolderPickerResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            path = url.path(percentEncoded: false)
            addPath()
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }
}
