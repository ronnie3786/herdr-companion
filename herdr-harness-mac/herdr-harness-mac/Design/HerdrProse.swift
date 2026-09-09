import AppKit
import SwiftUI

/// Comfortable reading typography for rendered chat output. Prose uses the
/// native system face at full contrast; activity and code remain distinct
/// through their smaller size and restrained foreground colors.
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

        /// Base point size at 100% font scale (before `HerdrFontScale`).
        var baseSize: CGFloat {
            switch self {
            case .body, .quote, .listItem: 17
            case .heading1: 23
            case .heading2: 20
            case .heading3: 18
            case .heading4, .heading5, .heading6: 17
            case .tableHeader, .tableCell: 15
            }
        }

        var weight: Font.Weight {
            switch self {
            case .body, .quote, .listItem, .tableCell: .regular
            case .heading1, .heading2, .heading3: .semibold
            case .heading4: .semibold
            case .heading5, .heading6: .semibold
            case .tableHeader: .semibold
            }
        }

        /// Quotes retain their typographic distinction within the system face.
        var isItalic: Bool { self == .quote }
    }

    /// Spacing between adjacent markdown blocks (paragraph, heading, list,
    /// quote, table, code) inside a single rendered message.
    static let blockSpacing: CGFloat = 18

    /// Spacing between conversation turns in `PiChatTimelineView`.
    static let turnSpacing: CGFloat = 32

    /// How far "sub-output" cards — thinking disclosures, tool cards, and
    /// working groups — are dimmed so they read as visually recessive relative
    /// to Pi's actual output prose. Applied to the cards' foreground colours
    /// (`dimmed(_:)`), never as `.opacity` on the whole card: a group-opacity
    /// on each of a hundred cards cost ~170 ms per card per layout pass.
    static let subOutputOpacity: Double = 0.9

    /// A card foreground colour at `subOutputOpacity`.
    static func dimmed(_ color: Color) -> Color {
        color.opacity(subOutputOpacity)
    }

    /// Keep the existing global font-scale preference effective for every role.
    static func font(_ role: Role, scale: HerdrFontScale) -> Font {
        let font = Font.system(size: role.baseSize * scale.rawValue, weight: role.weight)
        return role.isItalic ? font.italic() : font
    }

    /// Monospaced chip font for inline `code` spans within prose, sized
    /// relative to the surrounding role and the user's font-scale preference.
    static func inlineCodeFont(_ role: Role, scale: HerdrFontScale) -> Font {
        .system(size: (role.baseSize * 0.9 * scale.rawValue).rounded(), weight: .regular, design: .monospaced)
    }

    /// Foreground color for inline `code` spans within prose.
    static let inlineCodeColor: Color = HerdrTheme.code

    /// `.lineSpacing(...)` for reading-prose roles (body, quote, list items)
    /// at the given scale. Call sites for headings and tables keep their own
    /// existing tight spacing instead of calling this.
    static func lineSpacing(_ role: Role, scale: HerdrFontScale) -> CGFloat {
        (8 * scale.rawValue).rounded()
    }

    /// Extra space ABOVE a heading, added on top of `blockSpacing`, so
    /// headings read as new sections rather than just another paragraph.
    static func headingTopSpacing(_ level: Int) -> CGFloat {
        switch level {
        case ...2: 12
        case 3: 6
        default: 2
        }
    }

    /// Runtime check that the bundled Inter-Regular face actually resolves.
    /// Used by a unit test to catch bundling regressions (e.g. a missing
    /// Fonts/ resource or a stale `ATSApplicationFontsPath`) in CI.
    static func isInterRegularAvailable() -> Bool {
        NSFont(name: "Inter-Regular", size: 12) != nil
    }
}
