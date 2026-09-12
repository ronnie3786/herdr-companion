import SwiftUI
import UIKit

/// Typography for Pi's rendered assistant OUTPUT prose: the markdown message
/// body (paragraphs, headings, lists, quotes, tables). This is the seam that
/// makes Pi's actual output visually unmistakable versus the surrounding
/// chrome — output renders in Inter at full contrast, while thinking
/// disclosures and tool cards (`PiThinkingDisclosureView`, `PiToolCardView`,
/// `PiWorkingGroupView`)
/// keep their existing system/mono fonts and instead turn visually recessive
/// via `subOutputOpacity`. Code blocks stay monospaced everywhere; they're
/// code, not prose.
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

        /// Base point size before Dynamic Type scaling.
        var baseSize: CGFloat {
            switch self {
            case .body, .quote, .listItem: 15
            case .heading1: 20
            case .heading2: 17
            case .heading3: 15
            case .heading4: 13
            case .heading5: 12
            case .heading6: 11
            case .tableHeader, .tableCell: 14
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

        /// Block quotes render in Inter's real italic face rather than a
        /// synthetic slant.
        var isItalic: Bool { self == .quote }

        /// The Dynamic Type anchor this role tracks, so accessibility text
        /// sizes still scale Inter output on iOS.
        var textStyle: Font.TextStyle {
            switch self {
            case .body, .quote, .listItem: .body
            case .heading1: .title2
            case .heading2: .title3
            case .heading3: .headline
            case .heading4: .subheadline
            case .heading5: .footnote
            case .heading6: .caption
            case .tableHeader, .tableCell: .callout
            }
        }
    }

    /// Spacing between adjacent markdown blocks (paragraph, heading, list,
    /// quote, table, code) inside a single rendered message.
    static let blockSpacing: CGFloat = 12

    /// Spacing between conversation turns in `PiChatTimelineView`.
    static let turnSpacing: CGFloat = 28

    /// How far "sub-output" cards — thinking disclosures, tool cards, and
    /// working groups — are dimmed so they read as visually recessive relative
    /// to Pi's actual output prose. Applied to the cards' foreground colours
    /// (`dimmed(_:)`), never as `.opacity` on the whole card: a group-opacity
    /// on each of a hundred cards cost ~170 ms per card per layout pass.
    static let subOutputOpacity: Double = 0.78

    /// A card foreground colour at `subOutputOpacity`.
    static func dimmed(_ color: Color) -> Color {
        color.opacity(subOutputOpacity)
    }

    /// System font for a role, preserving its established default point size
    /// while continuing to follow the role's Dynamic Type text style.
    static func font(_ role: Role) -> Font {
        var font = role.textStyle.systemFont
            .scaled(by: role.baseSize / role.textStyle.defaultPointSize)
            .weight(role.weight)
        if role.isItalic { font = font.italic() }
        return font
    }

    /// Monospaced system font for inline `code`, scaled from the same Dynamic
    /// Type anchor as its surrounding prose role.
    static func inlineCodeFont(_ role: Role) -> Font {
        role.textStyle.systemFont
            .scaled(by: inlineCodeSize(for: role) / role.textStyle.defaultPointSize)
            .monospaced()
            .weight(.medium)
    }

    static func inlineCodeSize(for role: Role) -> CGFloat {
        (role.baseSize * 0.9).rounded()
    }

    /// Foreground color for inline `code` spans within prose.
    static let inlineCodeColor: Color = HerdrTheme.code

    /// `.lineSpacing(...)` for reading-prose roles (body, quote, list items).
    /// Call sites for headings and tables keep their own existing tight
    /// spacing instead of calling this.
    static func lineSpacing(_ role: Role) -> CGFloat {
        (role.baseSize * 0.35).rounded()
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

    /// Runtime check that the still-bundled Inter-Regular asset resolves.
    /// The mobile chat now uses system prose; retaining this check prevents the
    /// focused visual revision from silently turning into unrelated asset work.
    static func isInterRegularAvailable() -> Bool {
        UIFont(name: "Inter-Regular", size: 12) != nil
    }
}

private extension Font.TextStyle {
    var systemFont: Font {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        @unknown default: .body
        }
    }

    /// Default iOS point sizes for the semantic styles. Scaling a semantic
    /// system font by the role's ratio retains Dynamic Type behavior while
    /// matching Herdr's established default prose hierarchy.
    var defaultPointSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .subheadline: 15
        case .callout: 16
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}
