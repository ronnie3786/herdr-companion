import SwiftUI

/// How dense First Mate's rendered Markdown is: `.document` for resources
/// (14/24 prose), `.compact` for the Overview's goal and journal (13/20).
enum FirstMateMarkdownDensity: Sendable {
    case document, compact

    /// Point size at 100% for a role.
    func size(_ role: HerdrProse.Role) -> CGFloat {
        guard self == .compact else { return role.baseSize }
        switch role {
        case .heading1: return 15
        case .heading2: return 14
        case .tableHeader, .tableCell: return 12
        default: return 13
        }
    }

    func lineHeight(_ role: HerdrProse.Role) -> CGFloat {
        self == .compact ? 20 : role.lineHeight
    }

    func lineSpacing(_ role: HerdrProse.Role, scale: HerdrFontScale) -> CGFloat {
        HerdrProse.lineSpacing(size: size(role), lineHeight: lineHeight(role), scale: scale)
    }
}

extension EnvironmentValues {
    @Entry var firstMateMarkdownDensity: FirstMateMarkdownDensity = .document
}

struct FirstMateMarkdownText: View {
    let source: String
    let role: HerdrProse.Role
    let color: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.firstMateMarkdownDensity) private var density

    init(_ source: String, role: HerdrProse.Role, color: Color? = nil) {
        self.source = source
        self.role = role
        self.color = color
    }

    var body: some View {
        let palette = FirstMatePalette(scheme: scheme)
        let size = density.size(role)
        let rendered = PiMarkdownInlineCache.shared.rendered(source)
        // Inline code and bold read in full ink; code sits on an 8% chip.
        let styled = PiMarkdownInlineCache.shared.styled(
            rendered,
            source: source,
            font: .system(size: (size * 0.8 * fontScale.rawValue).rounded(), design: .monospaced),
            color: palette.text,
            background: palette.chipFill,
            strongFont: .system(size: size * fontScale.rawValue, weight: .semibold),
            strongColor: palette.text
        )
        Text(styled)
            .font(font(size: size))
            .foregroundStyle(color ?? (isHeading ? palette.text : palette.proseText))
            .tint(palette.accent)
            .textSelection(.enabled)
    }

    private var isHeading: Bool {
        switch role {
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .tableHeader: true
        default: false
        }
    }

    private func font(size: CGFloat) -> Font {
        let font = Font.system(size: size * fontScale.rawValue, weight: role.weight)
        return role.isItalic ? font.italic() : font
    }
}
