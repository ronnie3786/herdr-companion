import SwiftUI

/// Colors and type for a skim in one host. First Mate follows its own light or
/// dark palette; HUD chats use Herdr's dark reading surface. Each host keeps
/// its Markdown renderer, so a verbatim excerpt reads like that host's reply.
struct SkimStyle {
    enum Host: Equatable, Sendable {
        case firstMate
        case hud
    }

    var host: Host
    var isDark: Bool
    var text: Color
    var secondaryText: Color
    var tertiaryText: Color
    var accent: Color
    /// The suggested next step: the only thing the reader acts on.
    var attention: Color
    /// A caveat's rule.
    var alert: Color
    var success: Color
    var line: Color
    /// Verbatim excerpts sit on a deeper "source" surface than generated text.
    var sourceSurface: Color
    var codeSurface: Color
    var codeLine: Color
    /// One breath: a little larger than the reply's body text.
    var sentenceFont: Font
    var bodyFont: Font
    var caveatFont: Font
    var codeFont: Font
    /// Inline `code` in generated text. Nil keeps First Mate's Markdown style
    /// (the code presentation intent), exactly like its replies.
    var inlineCodeFont: Font?
    var inlineCodeColor: Color?
    var lineSpacing: CGFloat
    /// Gaps the host's full reply uses between blocks and between list items.
    var blockSpacing: CGFloat
    var itemSpacing: CGFloat

    static func firstMate(_ scheme: ColorScheme) -> SkimStyle {
        let palette = FirstMatePalette(scheme: scheme)
        let dark = scheme == .dark
        return SkimStyle(
            host: .firstMate,
            isDark: dark,
            text: palette.text,
            secondaryText: palette.secondaryText,
            tertiaryText: palette.secondaryText,
            accent: palette.accent,
            // Light keeps the deepened orange First Mate's status label uses.
            attention: dark ? HerdrTheme.attention : Color(red: 0.55, green: 0.35, blue: 0.05),
            alert: dark ? HerdrTheme.alert : Color(red: 0.65, green: 0.13, blue: 0.26),
            success: dark ? HerdrTheme.success : Color(red: 0.12, green: 0.43, blue: 0.34),
            line: palette.line,
            sourceSurface: dark ? rgb(0x12, 0x13, 0x19) : rgb(0xF0, 0xF1, 0xF5),
            codeSurface: dark ? rgb(0x0E, 0x0F, 0x14) : rgb(0xFF, 0xFF, 0xFF),
            codeLine: palette.line,
            sentenceFont: Font.body.scaled(by: 1.07),
            bodyFont: .body,
            caveatFont: Font.body.scaled(by: 0.92),
            codeFont: Font.footnote.monospaced(),
            inlineCodeFont: nil,
            inlineCodeColor: nil,
            lineSpacing: 5,
            blockSpacing: 16,
            itemSpacing: 9
        )
    }

    static var hud: SkimStyle {
        SkimStyle(
            host: .hud,
            isDark: true,
            text: HerdrTheme.text,
            secondaryText: HerdrTheme.mist,
            tertiaryText: HerdrTheme.muted,
            accent: HerdrTheme.accent,
            attention: HerdrTheme.attention,
            alert: HerdrTheme.alert,
            success: HerdrTheme.success,
            line: HerdrTheme.surface,
            sourceSurface: HerdrTheme.crust,
            codeSurface: rgb(0x10, 0x11, 0x18),
            codeLine: HerdrTheme.subtleSeparator,
            sentenceFont: HerdrProse.font(.body).scaled(by: 1.07),
            bodyFont: HerdrProse.font(.body),
            caveatFont: HerdrProse.font(.body).scaled(by: 0.92),
            codeFont: Font.footnote.monospaced(),
            inlineCodeFont: HerdrProse.inlineCodeFont(.body),
            inlineCodeColor: HerdrProse.inlineCodeColor,
            lineSpacing: HerdrProse.lineSpacing(.body),
            blockSpacing: HerdrProse.blockSpacing,
            itemSpacing: 6
        )
    }

    /// Token colors for highlighted code: Herdr's pastels in dark, the lab's
    /// paper palette in light. Line tints are separate (`lineTint`).
    func tokenColor(_ style: SkimCodeHighlighter.Style) -> Color? {
        switch style {
        case .keyword: isDark ? HerdrTheme.accent : Self.rgb(0x55, 0x50, 0xC4)
        case .string: isDark ? HerdrTheme.success : Self.rgb(0x2F, 0x7A, 0x43)
        case .comment: isDark ? Self.rgb(0x7F, 0x82, 0x96) : Self.rgb(0x6E, 0x71, 0x84)
        case .number: isDark ? HerdrTheme.working : Self.rgb(0x93, 0x62, 0x0C)
        case .function, .hunk: isDark ? HerdrTheme.primaryAction : Self.rgb(0x2F, 0x55, 0xC4)
        case .type: isDark ? HerdrTheme.signal : Self.rgb(0x1F, 0x7A, 0x6E)
        case .attribute, .property: isDark ? HerdrTheme.warning : Self.rgb(0xA3, 0x57, 0x2A)
        case .added, .removed: nil
        }
    }

    /// Whole-line tints: added and removed diff lines, passing and failing test output.
    func lineTint(_ style: SkimCodeHighlighter.Style?) -> Color {
        switch style {
        case .added: isDark ? HerdrTheme.diffAdd.opacity(0.16) : Self.rgb(0x2F, 0x7A, 0x43).opacity(0.12)
        case .removed: isDark ? HerdrTheme.diffRemove.opacity(0.16) : Self.rgb(0xA4, 0x44, 0x5C).opacity(0.12)
        default: .clear
        }
    }

    /// The host's own Markdown renderer: the same view its full replies use.
    @MainActor
    @ViewBuilder
    func replyMarkdown(_ source: String) -> some View {
        switch host {
        case .firstMate:
            FirstMateDocumentContentView(source: source)
        case .hud:
            PiMarkdownMessageView(source: source, isStreaming: false)
                .textSelection(.enabled)
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
