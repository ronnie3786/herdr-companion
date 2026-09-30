import AppKit
import SwiftUI
import os

/// Mono × Herdr typography for rendered chat output: MonoCode's 15/24 prose at
/// ink 78%, 18/26 headings, and inline code as an ink chip. Activity and code
/// stay distinct through size and tone, never through low-contrast dimming.
enum HerdrProse {
    /// A semantic role within Pi's rendered markdown output.
    enum Role: CaseIterable, Sendable {
        case body
        case quote
        case listItem
        case heading1
        case heading2
        case heading3
        case heading4
        case heading5
        case heading6
        case tableHeader
        case tableCell
        /// The user's own prompt in its bubble.
        case userBubble

        /// Base point size at 100% font scale (before `HerdrFontScale`).
        var baseSize: CGFloat {
            switch self {
            case .body, .quote, .listItem, .userBubble: 15
            case .heading1, .heading2: 18
            case .heading3, .heading4, .heading5, .heading6: 15
            case .tableHeader, .tableCell: 14
            }
        }

        /// Target line height at 100% (MonoCode's leading).
        var lineHeight: CGFloat {
            switch self {
            case .body, .quote, .listItem: 24
            case .heading1, .heading2: 26
            case .heading3, .heading4, .heading5, .heading6: 20
            case .tableHeader, .tableCell: 18
            case .userBubble: 20
            }
        }

        var weight: Font.Weight {
            switch self {
            case .body, .quote, .listItem, .tableCell, .userBubble: .regular
            case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: .semibold
            case .tableHeader: .semibold
            }
        }

        /// Quotes retain their typographic distinction within the system face.
        var isItalic: Bool { self == .quote }
    }

    /// Spacing between adjacent markdown blocks (paragraph, heading, list,
    /// quote, table, code) inside a single rendered message.
    static let blockSpacing: CGFloat = 16

    /// Spacing between conversation turns in `PiChatTimelineView`.
    static let turnSpacing: CGFloat = 24

    /// Kept for callers that still dim sub-output *icons*. Text never uses it:
    /// tertiary ink × 0.9 falls below 4.5:1 on a 10% fill.
    static let subOutputOpacity: Double = 0.9

    /// A card foreground colour at `subOutputOpacity`. Icons only.
    static func dimmed(_ color: Color) -> Color {
        color.opacity(subOutputOpacity)
    }

    /// Keep the existing global font-scale preference effective for every role.
    static func font(_ role: Role, scale: HerdrFontScale) -> Font {
        let font = Font.system(size: role.baseSize * scale.rawValue, weight: role.weight)
        return role.isItalic ? font.italic() : font
    }

    /// Monospaced chip font for inline `code` spans: 0.8em of the surrounding
    /// role, like MonoCode's `code { font-size: .8em }`.
    static func inlineCodeFont(_ role: Role, scale: HerdrFontScale) -> Font {
        .system(size: (role.baseSize * 0.8 * scale.rawValue).rounded(), weight: .regular, design: .monospaced)
    }

    /// Foreground color for inline `code` spans within prose: full ink on a chip.
    static let inlineCodeColor: Color = HerdrTheme.primaryText

    /// `.lineSpacing(...)` that makes `role` reach its MonoCode line height at
    /// this scale. AppKit's natural line height is subtracted so the result is
    /// exact rather than a flat allowance.
    static func lineSpacing(_ role: Role, scale: HerdrFontScale) -> CGFloat {
        lineSpacing(size: role.baseSize, lineHeight: role.lineHeight, scale: scale)
    }

    /// Line spacing for an arbitrary size and target line height.
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat, scale: HerdrFontScale, monospaced: Bool = false) -> CGFloat {
        let key = LineSpacingKey(size: size, lineHeight: lineHeight, scale: scale.rawValue, monospaced: monospaced)
        if let cached = lineSpacingCache.withLock({ $0[key] }) { return cached }
        let pointSize = size * scale.rawValue
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            : NSFont.systemFont(ofSize: pointSize)
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        let spacing = max(0, (lineHeight * scale.rawValue - natural).rounded())
        lineSpacingCache.withLock { $0[key] = spacing }
        return spacing
    }

    private struct LineSpacingKey: Hashable, Sendable {
        let size: CGFloat
        let lineHeight: CGFloat
        let scale: Double
        let monospaced: Bool
    }

    private static let lineSpacingCache = OSAllocatedUnfairLock<[LineSpacingKey: CGFloat]>(initialState: [:])

    /// Extra space ABOVE a heading, added on top of `blockSpacing`, so a
    /// heading gets MonoCode's 24pt top margin.
    static func headingTopSpacing(_ level: Int) -> CGFloat {
        level <= 2 ? 8 : 4
    }

    /// Runtime check that the bundled Inter-Regular face actually resolves.
    /// Used by a unit test to catch bundling regressions (e.g. a missing
    /// Fonts/ resource or a stale `ATSApplicationFontsPath`) in CI.
    static func isInterRegularAvailable() -> Bool {
        NSFont(name: "Inter-Regular", size: 12) != nil
    }
}
