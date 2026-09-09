import SwiftUI

struct PiUserMessageView: View {
    let message: PiUserMessage
    @Environment(\.herdrFontScale) private var fontScale
    @State private var labelCache = PiUserMessageLabelCache()

    var body: some View {
        let accessibilityLabel = labelCache.accessibilityLabel(for: message)
        // A trailing-aligned frame instead of `HStack { Spacer; bubble }`: the
        // stack would size-probe the bubble at several widths per layout pass.
        PiMarkdownText(message.text, font: HerdrProse.font(.body, scale: fontScale))
            .lineSpacing(HerdrProse.lineSpacing(.body, scale: fontScale))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(HerdrTheme.elevated, in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .stroke(HerdrTheme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            // Attached to the bubble rather than the row: the row is full width,
            // so a row-level overlay strands the control at the far left while
            // the bubble hugs the right. Offset into the leading gutter the
            // 42pt pad already reserves, so it never sits over the text.
            .piCopyAffordance(
                message.text,
                label: "Copy prompt",
                identifier: "pi-user-copy-\(message.id)",
                alignment: .topLeading,
                offset: CGSize(width: -28, height: 4)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 42)
    }
}

private final class PiUserMessageLabelCache {
    private var id: String?
    private var source: String?
    private var label: String?

    func accessibilityLabel(for message: PiUserMessage) -> String {
        if id == message.id, source == message.text, let label {
            return label
        }
        let label = "You: \(message.text)"
        id = message.id
        source = message.text
        self.label = label
        return label
    }
}
