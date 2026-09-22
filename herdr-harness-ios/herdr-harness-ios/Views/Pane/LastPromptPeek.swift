import SwiftUI

struct LastPromptPeekSheet: View {
    let message: PiUserMessage
    let copy: () -> Void
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("last prompt")
                        .font(.headline.monospaced().weight(.bold))
                        .foregroundStyle(HerdrTheme.text)
                    timestampCaption
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        copyPrompt()
                    }
                    .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("pane-last-prompt-copy")
                    .accessibilityLabel(copied ? "Prompt copied" : "Copy prompt")
                    .composerLayoutMeasurement(id: "pane-last-prompt-copy", label: "Copy prompt")

                    Button("Done", systemImage: "xmark", action: dismiss)
                        .foregroundStyle(HerdrTheme.mist)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("pane-last-prompt-dismiss")
                        .composerLayoutMeasurement(id: "pane-last-prompt-dismiss", label: "Done")
                }
                .font(.caption.monospaced().weight(.medium))
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)

            ScrollView {
                PiMarkdownText(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
        }
        .padding(HerdrTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.ink)
    }

    @ViewBuilder
    private var timestampCaption: some View {
        if let timestamp = message.timestamp {
            Text("what you asked · \(timestamp, style: .relative)")
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)
        } else {
            Text("what you asked")
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)
        }
    }

    private func copyPrompt() {
        copy()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
