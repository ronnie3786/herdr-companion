import SwiftUI

struct FirstMateFolderBrowserContents: View {
    @Bindable var model: FirstMateFolderBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView("Loading folders…")
                    .herdrFont(.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("first-mate-folder-loading")
            } else if model.error != nil && model.entries.isEmpty {
                FirstMateFolderBrowserError(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasLoadedCurrentDirectory && model.entries.isEmpty {
                ContentUnavailableView("No folders here", systemImage: "folder", description: Text(
                    model.showHidden ? "You can use this folder, or open another location." : "You can use this folder, open another location, or show hidden folders."
                ))
                .herdrFont(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("first-mate-folder-empty")
            } else {
                List(selection: $model.selectedEntryPath) {
                    ForEach(model.entries) { entry in
                        FirstMateFolderBrowserRow(entry: entry) { model.open(entry) }
                            .tag(entry.path)
                            .listRowSeparator(.hidden)
                            .onTapGesture(count: 2) { model.open(entry) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .disabled(!model.isConnectionValid)
                .onKeyPress(.return) {
                    guard model.canOpenSelectedFolder else { return .ignored }
                    model.openSelectedFolder()
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard model.canOpenSelectedFolder else { return .ignored }
                    model.openSelectedFolder()
                    return .handled
                }
                .accessibilityLabel("Folders")
                .accessibilityIdentifier("first-mate-folder-list")

                if model.error != nil {
                    FirstMateFolderBrowserError(model: model)
                } else if model.isLoadingMore {
                    ProgressView("Loading more folders…")
                        .controlSize(.small)
                        .padding(12)
                } else if model.nextCursor != nil {
                    Button("Load more folders", action: loadMore)
                        .buttonStyle(HerdrButtonStyle(kind: .ghost))
                        .disabled(!model.isConnectionValid)
                        .padding(8)
                        .accessibilityIdentifier("first-mate-folder-more")
                }
            }
        }
    }

    private func loadMore() { model.loadMore() }
}
