import SwiftUI

struct PaneGitWebView: View {
    let document: PaneGitWebDocument

    @State private var phase: PaneGitWebLoadPhase = .loading
    @State private var reloadID = 0

    init(configuration: ServerConfiguration, workspaceID: String, paneID: String) {
        document = PaneGitWebDocument(
            configuration: configuration,
            workspaceID: workspaceID,
            paneID: paneID
        )
    }

    init(configuration: ServerConfiguration, firstMateTarget: FirstMateGitWindowTarget) {
        document = PaneGitWebDocument(configuration: configuration, firstMateTarget: firstMateTarget)
    }

    var body: some View {
        ZStack {
            PaneGitWebContainer(document: document, phase: $phase)
            .id(reloadID)

            switch phase {
            case .loading:
                loadingView
            case .ready:
                EmptyView()
            case let .failed(message):
                failureView(message: message)
            }
        }
        .background(HerdrTheme.windowBackground)
        .accessibilityIdentifier("pane-git-web")
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading Git changes…")
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(HerdrTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.windowBackground.opacity(0.94))
        .accessibilityElement(children: .combine)
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Git view unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") {
                phase = .loading
                reloadID &+= 1
            }
            .herdrProminentButton()
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.windowBackground)
    }
}
