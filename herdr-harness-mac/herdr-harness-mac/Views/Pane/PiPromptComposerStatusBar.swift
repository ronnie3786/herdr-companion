import SwiftUI

/// Semantic run controls layered into the full Herdr composer while Pi works.
struct PiPromptComposerStatusBar: View {
    let disposition: PiPromptDisposition
    let availableDispositions: [PiPromptDisposition]
    let canSelectDisposition: Bool
    let canAbort: Bool
    let selectDisposition: (PiPromptDisposition) -> Void
    let stop: () -> Void
    var showsStatusLabel = true

    var body: some View {
        HStack(spacing: 8) {
            if showsStatusLabel {
                Label("Pi is working", systemImage: "sparkles")
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.working)
                Spacer(minLength: 4)
            }

            Menu {
                ForEach(availableDispositions) { option in
                    Button {
                        selectDisposition(option)
                    } label: {
                        Label(
                            option.label,
                            systemImage: disposition == option
                                ? "checkmark.circle.fill"
                                : option.symbol
                        )
                    }
                }
            } label: {
                Label(disposition.shortLabel, systemImage: disposition.symbol)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 4)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            }
            .piChipMenu()
            .disabled(!canSelectDisposition || availableDispositions.isEmpty)
            .accessibilityLabel("Prompt mode: \(disposition.label)")
            .accessibilityIdentifier("pi-chat-disposition")

            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.alert, emphasis: .text))
                .herdrFont(.caption, weight: .semibold)
                .frame(minHeight: PiChatChrome.controlHeight)
                .disabled(!canAbort)
                .accessibilityIdentifier("pi-chat-stop")
        }
        .padding(.horizontal, showsStatusLabel ? 4 : 0)
        .accessibilityElement(children: .contain)
    }
}

/// Compaction stays visible in the composer status area even while Pi reports
/// an otherwise idle session. Progress keeps the existing spinner; confirmed
/// success shows a checkmark plus readiness copy. There are intentionally no
/// prompt controls here because accepting a model, thinking, or message command
/// during summary generation is unsafe.
struct PiCompactionStatusBar: View {
    let presentation: PiCompactionStatusPresentation

    init(presentation: PiCompactionStatusPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(titleColor)
                if let detail = presentation.detail {
                    Text(detail)
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.kind {
        case .progress:
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.working)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: presentation.systemImage)
                .foregroundStyle(HerdrTheme.success)
                .accessibilityHidden(true)
        }
    }

    private var titleColor: Color {
        switch presentation.kind {
        case .progress: HerdrTheme.working
        case .completed: HerdrTheme.success
        }
    }
}
