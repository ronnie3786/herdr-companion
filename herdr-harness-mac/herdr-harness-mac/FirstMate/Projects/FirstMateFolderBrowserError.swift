import SwiftUI

struct FirstMateFolderBrowserError: View {
    let model: FirstMateFolderBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t load this folder", systemImage: "exclamationmark.triangle")
                .herdrFont(.headline)
            Text(model.error ?? "The folder is unavailable.")
                .herdrFont(.body)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("first-mate-folder-error-message")
            if model.isConnectionValid {
                HStack(spacing: 12) {
                    Button("Try again", action: retry)
                        .buttonStyle(HerdrButtonStyle())
                        .accessibilityIdentifier("first-mate-folder-retry")
                    if model.hasLoadedCurrentDirectory {
                        Button("Reload folder", action: model.reloadCurrentFolder)
                            .buttonStyle(HerdrButtonStyle(kind: .ghost))
                            .accessibilityIdentifier("first-mate-folder-reload")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-folder-error")
    }

    private func retry() { model.retry() }
}
