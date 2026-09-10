import AppKit
import SwiftUI

struct PiCodeBlockView: View {
    let language: String?
    let code: String
    /// Composed into the copy control's identifier. `PiMarkdownBlock.id` is only
    /// the block's index within its own message, so it collides across the
    /// timeline without the owning message's id.
    var ownerID: String = ""
    var blockID: Int = 0
    @State private var copied = false
    @Environment(\.saveChatQuote) private var saveQuote
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.mist)
                Spacer()
                Button {
                    copyCode()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .herdrHitTarget(minWidth: 0)
                }
                .herdrFont(.caption)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.mist)
                .buttonStyle(.plain)
                // Was hidden until hover, which made it read as missing. It now
                // rests at a low opacity — which also drops one tracking area
                // per code block from the timeline.
                .opacity(copied ? 1 : 0.8)
                .animation(PiChatChrome.hoverAnimation, value: copied)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
                .accessibilityIdentifier("pi-code-copy-\(ownerID)-\(blockID)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(HerdrTheme.elevated)

            Rectangle()
                .fill(HerdrTheme.separator)
                .frame(height: 1)

            ScrollView(.horizontal) {
                Group {
                    if saveQuote != nil {
                        ChatSelectableText(text: AttributedString(code), font: .system(size: 14 * fontScale.rawValue, design: .monospaced), lineSpacing: 4)
                            .frame(width: codeWidth)
                    } else {
                        Text(code)
                            .herdrFont(size: 14, monospaced: true)
                            .foregroundStyle(HerdrTheme.text)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.visible)
        }
        .background(HerdrTheme.ink, in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .clipShape(RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .stroke(HerdrTheme.separator, lineWidth: 1)
        }
    }

    private var codeWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 14 * fontScale.rawValue, weight: .regular)
        return max(120, code.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 120) + 2
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
