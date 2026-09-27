import SwiftUI

struct FirstMateMessageView: View {
    let message: FirstMateMessage
    /// The chat's skim choices: Skim or Full reply per message, and "Show in reply".
    let skimState: SkimReadingState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var human: Bool { message.role == "user" || message.role == "human" }
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    /// A ready skim that is valid for this exact reply, or nil (full reply).
    private var skimReader: FirstMateSkimReader? {
        guard !human, let reader = FirstMateSkimReader(skim: message.skim, reply: message.text) else { return nil }
        return SkimDisplay.hasContent(reader) ? reader : nil
    }

    var body: some View {
        let reader = skimReader
        HStack(alignment: .top, spacing: 0) {
            if human && !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    if !human {
                        Image(systemName: "sailboat.fill").foregroundStyle(palette.accent).accessibilityHidden(true)
                    }
                    Text(human ? "You" : "First Mate").font(.caption.weight(.semibold))
                    if message.status == "queued" {
                        Label("Queued", systemImage: "clock").font(.caption2).foregroundStyle(palette.secondaryText)
                    }
                    if !human, reader == nil, message.skim?.status == .pending {
                        Text("Skimming…")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .composerLayoutMeasurement(id: "skim-pending", label: "Skimming…")
                    }
                }
                if human {
                    Text(message.text)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SkimmableReply(messageID: message.id, reader: reader, style: .firstMate(scheme), state: skimState) {
                        FirstMateDocumentContentView(source: message.text)
                    }
                }
            }
            .foregroundStyle(palette.text)
            .padding(human ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(human ? palette.accent.opacity(scheme == .dark ? 0.13 : 0.08) : .clear, in: .rect(cornerRadius: 18))
        }
        // A skim's phrases, chip, and toggle each stay reachable on their own.
        .accessibilityElement(children: reader == nil ? .combine : .contain)
        .accessibilityIdentifier("first-mate-message-\(message.id)")
    }
}
