import SwiftUI

struct PiUserMessageView: View {
    let message: PiUserMessage
    @Environment(\.herdrFontScale) private var fontScale
    @State private var labelCache = PiUserMessageLabelCache()

    var body: some View {
        let accessibilityLabel = labelCache.accessibilityLabel(for: message)
        // A trailing-aligned frame instead of `HStack { Spacer; bubble }`: the
        // stack would size-probe the bubble at several widths per layout pass.
        PiMarkdownText(message.text, font: HerdrProse.font(.userBubble, scale: fontScale))
            .lineSpacing(HerdrProse.lineSpacing(.userBubble, scale: fontScale))
            .environment(\.chatProsePalette, Self.bubblePalette)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            // A pill while the prompt fits one line, 12pt corners beyond.
            .background(
                HerdrTheme.selectedFill,
                in: HerdrBubbleShape(singleLineHeight: (HerdrProse.Role.userBubble.lineHeight + 16) * fontScale.rawValue)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            // Attached to the bubble itself, before the 576pt cap: any wider
            // frame strands the control far left of a short bubble. Offset
            // into the leading gutter the 40pt pad reserves, so it never sits
            // over the text.
            .piCopyAffordance(
                message.text,
                label: "Copy prompt",
                identifier: "pi-user-copy-\(message.id)",
                alignment: .topLeading,
                offset: CGSize(width: -28, height: 4)
            )
            .frame(maxWidth: 576 * fontScale.rawValue, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            .padding(.bottom, 12)
    }

    /// The user's own words read in full ink.
    static let bubblePalette: ChatProsePalette = {
        var palette = ChatProsePalette.chat
        palette.text = HerdrTheme.primaryText
        return palette
    }()
}

/// MonoCode's message bubble: fully rounded while it holds one line, 12pt
/// corners once it wraps. Decided from its own height, with no geometry state.
struct HerdrBubbleShape: Shape {
    var singleLineHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = rect.height <= singleLineHeight + 1 ? rect.height / 2 : HerdrTheme.Radius.card
        return Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2))
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
