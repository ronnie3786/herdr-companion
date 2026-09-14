import SwiftUI

struct FirstMateMessageView: View {
    let message: FirstMateMessage
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var human: Bool { message.role == "user" || message.role == "human" }
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
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
                }
                if human {
                    Text(message.text)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FirstMateDocumentContentView(source: message.text)
                }
            }
            .foregroundStyle(palette.text)
            .padding(human ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(human ? palette.accent.opacity(scheme == .dark ? 0.13 : 0.08) : .clear, in: .rect(cornerRadius: 18))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-message-\(message.id)")
    }
}
