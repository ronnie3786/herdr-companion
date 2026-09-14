import SwiftUI

struct HerdrHudWorkingFolderPicker: View {
    let session: HerdrHudSession
    let machine: HerdrMachine
    @State private var isShowingEditor = false

    private var selectedPath: String {
        session.selectedWorkingFolder.displayPath(for: machine)
    }

    var body: some View {
        Menu {
            ForEach(session.workingFolderOptions(for: machine.id)) { folder in
                Button {
                    session.selectWorkingFolder(path: folder.path, for: machine.id)
                } label: {
                    if folder.path == session.selectedWorkingFolder.path {
                        Label(folder.displayPath(for: machine), systemImage: "checkmark")
                    } else {
                        Text(folder.displayPath(for: machine))
                    }
                }
            }
            if session.canEditWorkingFolder {
                Divider()
                Button("Manage folders…", systemImage: "folder.badge.gearshape") {
                    isShowingEditor = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: session.selectedWorkingFolder.isHome ? "house" : "folder")
                    .accessibilityHidden(true)
                Text(selectedPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                Image(systemName: "chevron.down")
                    .herdrFont(.caption2, weight: .bold)
                    .accessibilityHidden(true)
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(!session.canEditWorkingFolder)
        .help(
            session.canEditWorkingFolder
                ? "Choose the working folder for this new HUD chat"
                : "This chat keeps its original working folder"
        )
        .accessibilityLabel("HUD working folder: \(selectedPath)")
        .accessibilityIdentifier("hud-working-folder")
        .popover(isPresented: $isShowingEditor, arrowEdge: .bottom) {
            HerdrHudWorkingFolderEditorView(session: session, machine: machine)
                .id(machine.id)
        }
    }
}
