import AppKit
import SwiftUI
import os

/// Mono × Herdr: MonoCode's two-color generator with Herdr's lavender accent
/// and pastel status colors.
///
/// Every neutral comes from two colors, `base` and `foreground` (MonoCode calls
/// the second one "ink"). Fills and lines are `foreground` at an alpha, so they
/// stay correct over glass and over each other; text colors are the same alphas
/// composited over `base`, so their contrast is fixed and testable. Nothing a
/// person reads falls below 4.5:1 (`HerdrThemeAccessibilityTests`).
///
/// Older names (`graphite`, `elevated`, `mist`, …) remain as aliases of these
/// roles so every view reads as the new palette; components adopt the role
/// names and recipes in `HerdrRecipes.swift` as they are restyled.
enum HerdrTheme {
    // MARK: Generator

    /// hsl(240 8% 9%), #151519. The pane and window background.
    static let base = hsl(240, 8, 9)
    /// hsl(240 8% 92%), #E9E9EC. Primary text; every neutral fill is this at an alpha.
    static let foreground = hsl(240, 8, 92)

    /// `foreground` at `alpha`: translucent, for fills and lines that sit on
    /// any surface (including glass).
    static func inkFill(_ alpha: Double) -> Color {
        foreground.opacity(alpha)
    }

    /// `foreground` at `alpha` composited over `base`: opaque, for text and for
    /// surfaces that must hide what is behind them.
    static func inkSolid(_ alpha: Double) -> Color {
        composite(foregroundRGB, alpha, over: baseRGB)
    }

    // MARK: Surfaces

    static let windowBackground = base
    /// The sidebar rail: `base` darkened by 10%, #131317.
    static let railBackground = composite((0, 0, 0), 0.10, over: baseRGB)

    // MARK: Fills (translucent)

    /// Cards, the composer and folder groups.
    static let cardFill = inkFill(0.03)
    static let fieldFill = inkFill(0.04)
    /// Inset blocks inside cards (NOW, hunk bars) and hovered rows.
    static let insetFill = inkFill(0.05)
    static let hoverFill = inkFill(0.05)
    static let codeFill = inkFill(0.06)
    /// Inline code chips and document chips.
    static let chipFill = inkFill(0.08)
    /// Selected rows, tabs and pills, and the user's message bubble.
    static let selectedFill = inkFill(0.10)

    // MARK: Lines (translucent)

    /// Title bar, sidebar and section rules.
    static let hairline = inkFill(0.07)
    static let rowDivider = inkFill(0.05)
    /// Card, field and composer outlines.
    static let outline = inkFill(0.10)
    static let strongOutline = inkFill(0.15)
    static let focusOutline = inkFill(0.20)

    // MARK: Text (opaque)

    static let primaryText = foreground
    /// Rendered prose: 78%.
    static let proseText = inkSolid(0.78)
    /// Labels and secondary copy: 70%.
    static let secondaryText = inkSolid(0.70)
    /// Metadata, timestamps and placeholders: 64%, the lowest text level.
    static let tertiaryText = inkSolid(0.64)
    /// Glyph-only icons: 50%. Never use for words.
    static let iconTint = inkSolid(0.50)

    // MARK: Accent and actions

    static let accent = color(0xAAA6F4)
    /// Custom primary buttons (send, Agent view): lavender with a dark label.
    static let primaryAction = accent
    static let onPrimary = base
    static let primaryDisabled = accent.opacity(0.28)
    static let onPrimaryDisabled = base.opacity(0.55)
    // Native filled controls retain white labels on macOS, so their lavender
    // fill is deeper than the accent used for links and custom ink-label CTAs.
    static let controlAccent = color(0x5E59A8)
    /// Count badges (Git sections): lavender at 85% with a dark label.
    static let badgeFill = accent.opacity(0.85)
    static let onBadge = base
    /// The First Mate row's attention badge.
    static let attentionBadge = color(0xFF9F0A)
    static let onAttentionBadge = color(0x1A1A1A)
    /// Folder glyphs in the sidebar.
    static let folder = color(0xB9A7DF)
    /// The first bar of the brand mark and the blue note color.
    static let brandBlue = color(0xA6BAFF)

    // MARK: Status (Herdr's pastels, unchanged)

    static let signal = color(0x9CCDB9)
    static let success = color(0xA3CBA7)
    static let working = color(0xE4C386)
    static let alert = color(0xE2A7B6)
    static let warning = color(0xDFB38E)

    // MARK: Diff (MonoCode's source-control colors, Tailwind 4.3.3)

    /// Added lines: emerald-500 at 15%, gutter 25%, numbers emerald-300.
    static let diffAddRow = color(0x00BC7D).opacity(0.15)
    static let diffAddGutter = color(0x00BC7D).opacity(0.25)
    static let diffAddNumber = color(0x5EE9B5)
    /// Removed lines: rose-500 at 15%, gutter 25%, numbers rose-300.
    static let diffRemoveRow = color(0xFF2056).opacity(0.15)
    static let diffRemoveGutter = color(0xFF2056).opacity(0.25)
    static let diffRemoveNumber = color(0xFFA1AD)
    /// `+N` / `−N` counts and the A / D status letters.
    static let diffAdd = color(0x00D492)
    static let diffRemove = color(0xFF6467)
    /// The M and ? status letters.
    static let diffModified = color(0xFFB900)
    static let diffUntracked = color(0x00BCFF)
    static let diffHunk = tertiaryText

    /// MonoCode's dark syntax palette, used only inside code and diffs.
    enum Syntax {
        static let keyword = color(0xFF8FFD)
        static let callable = color(0xA5D5FE)
        static let string = color(0xB4FA72)
        static let type = color(0xFF8272)
        static let comment = color(0xFEFDC2)
        static let property = color(0xD0D1FE)
    }

    // MARK: Aliases (pre-Mono names)

    /// The darkest chrome: the sidebar rail, and dark labels on light fills.
    static let ink = railBackground
    static let graphite = windowBackground
    static let elevated = inkSolid(0.03)
    static let input = inkSolid(0.04)
    static let surface = inkSolid(0.10)
    static let selection = inkSolid(0.10)
    static let separator = outline
    static let subtleSeparator = hairline
    static let text = primaryText
    static let mist = secondaryText
    static let muted = tertiaryText
    static let mauve = folder
    /// Inline code reads as ink on a chip, not as a hue.
    static let code = primaryText
    /// Dark ink for colored note cards.
    static let crust = composite((0, 0, 0), 0.22, over: baseRGB)

    // MARK: Size ramp

    /// MonoCode's type ramp at 100%; `herdrFont(size:)` multiplies it by the
    /// app's font-scale preference.
    enum TextSize {
        static let micro: CGFloat = 10
        static let caption: CGFloat = 11
        static let small: CGFloat = 12
        static let body: CGFloat = 13
        static let reading: CGFloat = 14
        static let title: CGFloat = 18
    }

    /// Visual control heights. Anything interactive below 28 keeps a 28pt hit
    /// area through `herdrHitTarget()`.
    enum ControlHeight {
        static let mini: CGFloat = 20
        static let small: CGFloat = 24
        static let regular: CGFloat = 26
        static let large: CGFloat = 28
        static let row: CGFloat = 32
        static let bar: CGFloat = 36
        static let titleBar: CGFloat = 40
    }

    enum Radius {
        /// Controls, rows, pills and chips.
        static let control: CGFloat = 6
        /// The composer and NOW blocks.
        static let composer: CGFloat = 8
        /// Cards and popovers.
        static let card: CGFloat = 12
        /// Floating panels (HUD, palette).
        static let panel: CGFloat = 16
    }

    /// Legible glass: how much of `base` covers the blurred desktop.
    enum Glass {
        static let sidebar = 0.80
        static let pane = 0.75
        static let hud = 0.78
    }

    static let sidebarWidth: CGFloat = 260
    /// The centered transcript column.
    static let transcriptWidth: CGFloat = 896

    static let cardRadius = Radius.card
    static let compactRadius = Radius.composer
    static let pagePadding = 24.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0
    static let readingWidth = transcriptWidth
    static let transcriptGutter = 36.0

    // MARK: Color construction

    private typealias RGB = (Double, Double, Double)

    private static let baseRGB = hslComponents(240, 8, 9)
    private static let foregroundRGB = hslComponents(240, 8, 92)

    /// CSS `hsl()` rounded to whole sRGB channels, as MonoCode's generator does.
    private static func hslComponents(_ hue: Double, _ saturation: Double, _ lightness: Double) -> RGB {
        let s = saturation / 100, l = lightness / 100
        let a = s * min(l, 1 - l)
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let value = l - a * max(-1, min(k - 3, min(9 - k, 1)))
            return (value * 255).rounded()
        }
        return (channel(0), channel(8), channel(4))
    }

    private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> Color {
        rgbColor(hslComponents(hue, saturation, lightness))
    }

    private static func composite(_ top: RGB, _ alpha: Double, over bottom: RGB) -> Color {
        rgbColor((
            (top.0 * alpha + bottom.0 * (1 - alpha)).rounded(),
            (top.1 * alpha + bottom.1 * (1 - alpha)).rounded(),
            (top.2 * alpha + bottom.2 * (1 - alpha)).rounded()
        ))
    }

    private static func rgbColor(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, opacity: 1)
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }

    /// The smallest square a pointer control may occupy.
    ///
    /// 28pt, not iOS's 44pt: Mac chrome is deliberately compact. Controls may
    /// draw at 20–26pt, but their hit area never shrinks below this
    /// (`herdrHitTarget()`).
    static let minHitTarget = 28.0
}

extension HerdrTheme {
    private struct ScaledFontKey: Hashable, Sendable {
        let style: Font.TextStyle
        let scale: Double
        let monospaced: Bool
        let weight: Font.Weight?
    }

    private static let scaledFontCache = OSAllocatedUnfairLock<[ScaledFontKey: Font]>(initialState: [:])

    /// Fallback font scaling: Apple documents `dynamicTypeSize` as having no
    /// effect on text size on macOS. Read AppKit's preferred point size and
    /// rebuild a concrete SwiftUI font scaled by the user's chosen value.
    static func scaled(
        _ style: Font.TextStyle,
        scale: HerdrFontScale,
        monospaced: Bool = false,
        weight: Font.Weight? = nil
    ) -> Font {
        let key = ScaledFontKey(style: style, scale: scale.rawValue, monospaced: monospaced, weight: weight)
        if let cached = scaledFontCache.withLock({ $0[key] }) {
            return cached
        }
        let base = NSFont.preferredFont(forTextStyle: style.appKitTextStyle)
        let font: Font = .system(
            size: base.pointSize * scale.rawValue,
            weight: weight ?? base.herdrFontWeight,
            design: monospaced ? .monospaced : .default
        )
        scaledFontCache.withLock { $0[key] = font }
        return font
    }
}

private extension NSFont {
    var herdrFontWeight: Font.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let value = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        let named: [(CGFloat, Font.Weight)] = [
            (NSFont.Weight.ultraLight.rawValue, .ultraLight),
            (NSFont.Weight.thin.rawValue, .thin),
            (NSFont.Weight.light.rawValue, .light),
            (NSFont.Weight.regular.rawValue, .regular),
            (NSFont.Weight.medium.rawValue, .medium),
            (NSFont.Weight.semibold.rawValue, .semibold),
            (NSFont.Weight.bold.rawValue, .bold),
            (NSFont.Weight.heavy.rawValue, .heavy),
            (NSFont.Weight.black.rawValue, .black),
        ]
        return named.min {
            abs($0.0 - CGFloat(value)) < abs($1.0 - CGFloat(value))
        }?.1 ?? .regular
    }
}

private extension Font.TextStyle {
    var appKitTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
