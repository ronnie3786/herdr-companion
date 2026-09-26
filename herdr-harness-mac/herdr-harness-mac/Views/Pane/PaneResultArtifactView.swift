import SwiftUI

/// Results stay available in their chat after reading clears the HUD indicator.
struct PaneResultArtifactView: View {
    let model: HerdrAppModel
    let artifact: AgentResultArtifact
    @State private var openFailure: ResultArtifactOpenFailure?

    private var phase: AgentResultArtifactPhase { model.resultArtifactPhase(id: artifact.id) }
    private var isBusy: Bool { phase == .opening || phase == .downloading }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: artifact.kind == .link ? "link" : "doc")
                            .herdrFont(size: HerdrTheme.TextSize.reading)
                            .foregroundStyle(HerdrTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.displayTitle)
                            .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                            .foregroundStyle(HerdrTheme.primaryText)
                            .lineLimit(2)
                        if let detail = artifact.url?.absoluteString ?? artifact.filename {
                            Text(detail)
                                .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(HerdrTheme.iconTint)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .herdrCard(radius: HerdrTheme.Radius.composer)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help("Open \(artifact.displayTitle)")
            .accessibilityIdentifier("pane-result-artifact-\(artifact.id)")

            if case let .failed(message) = phase {
                Text(message)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.alert)
            }
        }
        .resultArtifactOpenAlert(failure: $openFailure, model: model)
    }

    private func open() {
        Task { openFailure = await model.openResultArtifact(artifact) }
    }
}
