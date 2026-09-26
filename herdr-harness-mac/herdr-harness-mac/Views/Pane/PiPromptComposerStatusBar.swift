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
    /// The composer's primary button takes over Stop; other hosts keep this one.
    var showsStop = true

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
                // MonoCode's Steer pill: symbol and short label, no chevron.
                HStack(spacing: 4) {
                    Image(systemName: disposition.symbol)
                        .herdrFont(size: 12)
                    Text(disposition.shortLabel)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                }
                .foregroundStyle(HerdrTheme.primaryText)
                .composerChip(.standalone)
            }
            .piChipMenu()
            .disabled(!canSelectDisposition || availableDispositions.isEmpty)
            .accessibilityLabel("Prompt mode: \(disposition.label)")
            .accessibilityIdentifier("pi-chat-disposition")

            if showsStop {
                Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.alert, emphasis: .text))
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                    .frame(minHeight: PiChatChrome.controlHeight)
                    .disabled(!canAbort)
                    .accessibilityIdentifier("pi-chat-stop")
            }
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
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                    .foregroundStyle(titleColor)
                if let detail = presentation.detail {
                    Text(detail)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.secondaryText)
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
