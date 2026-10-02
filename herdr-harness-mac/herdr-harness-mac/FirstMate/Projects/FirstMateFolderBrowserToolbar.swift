import SwiftUI

struct FirstMateFolderBrowserToolbar: View {
    @Bindable var model: FirstMateFolderBrowserModel
    @FocusState private var pathIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Parent folder", systemImage: "arrow.up", action: model.goUp)
                    .buttonStyle(HerdrIconButtonStyle())
                    .disabled(model.parentPath == nil || model.isLoading || !model.isConnectionValid)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help("Open the parent folder (⌘↑)")
                    .accessibilityIdentifier("first-mate-folder-up")
                Button("Home", systemImage: "house", action: model.goHome)
                    .buttonStyle(HerdrIconButtonStyle())
                    .disabled(!model.isConnectionValid)
                    .help("Open this machine’s home folder")
                    .accessibilityIdentifier("first-mate-folder-home")
                TextField("Go to folder on \(model.machineName)", text: $model.pathDraft)
                    .herdrFont(.body, monospaced: true)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .herdrField(focused: pathIsFocused)
                    .focused($pathIsFocused)
                    .onSubmit(model.goToDraft)
                    .disabled(!model.isConnectionValid)
                    .accessibilityIdentifier("first-mate-folder-path")
                Button("Go", action: model.goToDraft)
                    .buttonStyle(HerdrButtonStyle())
                    .disabled(model.pathDraft.isEmpty || !model.isConnectionValid)
                    .accessibilityIdentifier("first-mate-folder-go")
            }
            HStack(spacing: 12) {
                Text("Folders on this machine")
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Spacer()
                Toggle("Hidden folders", isOn: $model.showHidden)
                    .toggleStyle(.checkbox)
                    .herdrFont(.callout)
                    .disabled(!model.isConnectionValid)
                    .accessibilityIdentifier("first-mate-folder-hidden")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .herdrHairline(.bottom)
        .onAppear { pathIsFocused = true }
    }
}
