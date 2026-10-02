import SwiftUI

struct FirstMateFolderBrowserView: View {
    @Bindable var model: FirstMateFolderBrowserModel
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Choose a project folder", systemImage: "folder")
                    .herdrFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                Label(model.machineName, systemImage: "desktopcomputer")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("first-mate-folder-machine")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)

            FirstMateFolderBrowserToolbar(model: model)
            FirstMateFolderBrowserContents(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(model.hasLoadedCurrentDirectory ? (model.currentPath ?? "") : "Open a folder to select it")
                        .herdrFont(.callout, monospaced: true)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(HerdrTheme.accent)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Current folder")
                .accessibilityValue(model.hasLoadedCurrentDirectory ? (model.currentPath ?? "") : "None selected")
                .accessibilityIdentifier("first-mate-folder-current-path")
                .help(model.currentPath ?? "Open a folder to select it")
                if model.hasUnsubmittedPath {
                    Text("Choose Go to open the path you entered before selecting it.")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                HStack(spacing: 12) {
                    Text(model.entries.count == 1 ? "1 folder" : "\(model.entries.count) folders")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .opacity(model.hasLoadedCurrentDirectory ? 1 : 0)
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                        .buttonStyle(HerdrButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Use this folder", action: useFolder)
                        .buttonStyle(HerdrButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canChooseCurrentFolder)
                        .accessibilityIdentifier("first-mate-folder-use")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.top)
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .background(HerdrTheme.base)
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 1_000, minHeight: 510, idealHeight: 560, maxHeight: 900)
        .task { model.loadIfNeeded() }
        .onChange(of: model.isConnectionValid) { _, valid in
            if !valid { model.invalidateConnection() }
        }
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("first-mate-folder-browser")
    }

    private func cancel() {
        model.cancel()
        dismiss()
    }

    private func useFolder() {
        guard let path = model.selectionPath() else { return }
        select(path)
        dismiss()
    }
}
