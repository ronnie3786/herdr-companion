import AppKit
import SwiftUI

/// MonoCode's code block: a 36pt header (language label, copy icon), a hairline,
/// then 14/20 monospaced code beside a fixed line-number gutter, all in an
/// ink 6% box with a 10% outline and 10pt corners.
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
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.piCodeBlockStyle) private var style
    @Environment(\.colorScheme) private var scheme

    private static let codeSize: CGFloat = 14
    private static let numberSize: CGFloat = 12
    private static let lineHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if style == .excerpt {
                    // Skim excerpts name the language and size, like the lab's code blocks.
                    Text(SkimCodeLanguage.label(language, code: code))
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(palette.secondaryText)
                    Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(palette.marker)
                } else {
                    Text((language ?? "code").lowercased())
                        .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button {
                    copyCode()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    if style == .excerpt {
                        Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                            .foregroundStyle(copied ? HerdrTheme.success : palette.secondaryText)
                            .padding(.horizontal, 6)
                            .frame(minHeight: HerdrTheme.minHitTarget)
                            .contentShape(.rect)
                    } else {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .herdrFont(size: 13)
                            .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.iconTint)
                            .herdrCompactHitTarget(visual: HerdrTheme.ControlHeight.small)
                    }
                }
                .buttonStyle(.herdrPlain)
                .animation(PiChatChrome.hoverAnimation, value: copied)
                .help(copied ? "Copied" : "Copy code")
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
                .accessibilityIdentifier("pi-code-copy-\(ownerID)-\(blockID)")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(minHeight: HerdrTheme.ControlHeight.bar)

            Rectangle()
                .fill(palette.blockOutline)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 8) {
                lineNumbers
                ScrollView(.horizontal) {
                    Group {
                        if saveQuote != nil {
                            ChatSelectableText(
                                text: AttributedString(code),
                                font: .system(size: Self.codeSize * fontScale.rawValue, design: .monospaced),
                                lineSpacing: codeLineSpacing
                            )
                            .frame(width: codeWidth)
                            .environment(\.chatProsePalette, codePalette)
                        } else if style == .excerpt {
                            // The chat's own TextKit metrics keep line numbers aligned.
                            ChatSelectableText(
                                text: SkimCodeStyling.highlighted(code, language: language, palette: codePalette, scheme: scheme),
                                font: .system(size: Self.codeSize * fontScale.rawValue, design: .monospaced),
                                lineSpacing: codeLineSpacing
                            )
                            .frame(width: codeWidth)
                            .environment(\.chatProsePalette, codePalette)
                        } else {
                            Text(code)
                                .herdrFont(size: Self.codeSize, monospaced: true)
                                .foregroundStyle(palette.code)
                                .textSelection(.enabled)
                                .lineSpacing(codeLineSpacing)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.visible)
            }
            .padding(.vertical, 10)
        }
        .background(palette.blockFill, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.blockOutline, lineWidth: 1)
        }
    }

    /// Fixed beside the scrolling code, so numbers stay put while long lines scroll.
    private var lineNumbers: some View {
        let count = max(1, code.components(separatedBy: .newlines).count)
        return Text((1...count).map(String.init).joined(separator: "\n"))
            .herdrFont(size: Self.numberSize, monospaced: true)
            .foregroundStyle(palette.marker)
            .multilineTextAlignment(.trailing)
            .lineSpacing(numberLineSpacing)
            .frame(width: 24 * fontScale.rawValue, alignment: .trailing)
            // Baseline-align the smaller numbers with their 14pt code lines.
            .padding(.top, 2 * fontScale.rawValue)
            .accessibilityHidden(true)
    }

    private var lineCount: Int { max(1, code.components(separatedBy: .newlines).count) }

    /// Code reads in full ink, not prose ink.
    private var codePalette: ChatProsePalette {
        var code = palette
        code.text = palette.code
        return code
    }

    private var codeLineSpacing: CGFloat {
        HerdrProse.lineSpacing(size: Self.codeSize, lineHeight: Self.lineHeight, scale: fontScale, monospaced: true)
    }

    private var numberLineSpacing: CGFloat {
        HerdrProse.lineSpacing(size: Self.numberSize, lineHeight: Self.lineHeight, scale: fontScale, monospaced: true)
    }

    private var codeWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: Self.codeSize * fontScale.rawValue, weight: .regular)
        return max(120, code.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 120) + 2
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

/// Where a code block is shown. Skim excerpts add the language name, line
/// count, a labeled Copy code, and syntax colors.
enum PiCodeBlockStyle: Equatable, Sendable {
    case chat, excerpt
}

extension EnvironmentValues {
    @Entry var piCodeBlockStyle: PiCodeBlockStyle = .chat
}
