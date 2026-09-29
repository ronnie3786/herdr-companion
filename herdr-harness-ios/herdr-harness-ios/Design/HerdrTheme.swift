import SwiftUI

/// Mono × Herdr, dark only. Translucent fills use foreground ink; reading
/// colors composite that ink over the base once, keeping contrast testable.
/// Legacy names preserve the layout of screens not yet adopting dusk glass.
enum HerdrTheme {
    static let base = color(0x151519)
    static let foreground = color(0xE9E9EC)

    static func inkFill(_ alpha: Double) -> Color { foreground.opacity(alpha) }

    static func inkSolid(_ alpha: Double) -> Color {
        composite((233, 233, 236), alpha, over: (21, 21, 25))
    }

    static let windowBackground = base
    static let railBackground = color(0x131317)
    static let cardFill = inkFill(0.03)
    static let fieldFill = inkFill(0.04)
    static let insetFill = inkFill(0.05)
    static let hoverFill = inkFill(0.05)
    static let codeFill = inkFill(0.06)
    static let chipFill = inkFill(0.08)
    static let selectedFill = inkFill(0.10)

    static let hairline = inkFill(0.07)
    static let rowDivider = inkFill(0.05)
    static let outline = inkFill(0.10)
    static let strongOutline = inkFill(0.15)
    static let focusOutline = inkFill(0.20)

    /// Recipes read the SwiftUI contrast environment. No adaptive/light color
    /// providers, global accessibility observers, or mutable palette state.
    static func rule(_ color: Color, contrast: ColorSchemeContrast) -> Color {
        guard contrast == .increased,
              [hairline, rowDivider, outline, strongOutline, focusOutline].contains(color)
        else { return color }
        return inkFill(0.16)
    }

    static let primaryText = foreground
    static let proseText = inkSolid(0.78)
    static let secondaryText = inkSolid(0.70)
    static let tertiaryText = inkSolid(0.70)
    /// Glyphs only, never reading text.
    static let iconTint = inkSolid(0.50)

    static let accent = color(0xAAA6F4)
    static let primaryAction = accent
    static let onPrimary = base
    static let primaryDisabled = accent.opacity(0.28)
    static let onPrimaryDisabled = base.opacity(0.55)
    static let controlAccent = color(0x5E59A8)
    static let badgeFill = accent.opacity(0.85)
    static let onBadge = onPrimary
    static let attentionBadge = color(0xFF9F0A)
    static let onAttentionBadge = color(0x1A1A1A)
    static let firstMateAvatarFill = color(0x2A2244)
    static let folder = color(0xB9A7DF)
    static let brandBlue = color(0xA6BAFF)

    static let signal = color(0x9CCDB9)
    static let success = color(0xA3CBA7)
    static let working = color(0xE4C386)
    static let alert = color(0xE2A7B6)
    static let warning = color(0xDFB38E)

    static let diffAddRow = color(0x00BC7D).opacity(0.15)
    static let diffAddGutter = color(0x00BC7D).opacity(0.25)
    static let diffAddNumber = color(0x5EE9B5)
    static let diffRemoveRow = color(0xFF2056).opacity(0.15)
    static let diffRemoveGutter = color(0xFF2056).opacity(0.25)
    static let diffRemoveNumber = color(0xFFA1AD)
    static let diffAdd = color(0x00D492)
    static let diffRemove = color(0xFF6467)
    static let diffModified = color(0xFFB900)
    static let diffUntracked = color(0x00BCFF)
    static let diffHunk = tertiaryText

    enum Syntax {
        static let keyword = color(0xFF8FFD)
        static let callable = color(0xA5D5FE)
        static let string = color(0xB4FA72)
        static let type = color(0xFF8272)
        static let comment = color(0xFEFDC2)
        static let property = color(0xD0D1FE)
    }

    // Pre-Mono aliases. Keep their existing iOS layout metrics.
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
    static let code = primaryText
    static let crust = composite((0, 0, 0), 0.22, over: (21, 21, 25))
    static let attention = attentionBadge

    enum TextSize {
        static let micro: CGFloat = 11
        static let caption: CGFloat = 13
        static let small: CGFloat = 15
        static let body: CGFloat = 16
        static let reading: CGFloat = 16
        static let title: CGFloat = 17
    }

    enum ControlHeight {
        static let mini: CGFloat = 20
        static let small: CGFloat = 28
        static let regular: CGFloat = 32
        static let large: CGFloat = 36
        static let row: CGFloat = 44
        static let bar: CGFloat = 44
        static let titleBar: CGFloat = 44
    }

    enum Radius {
        static let control: CGFloat = 6
        static let composer: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
        static let bubble: CGFloat = 18
        static let pill: CGFloat = 24
    }

    enum Glass {
        static let sidebar = 0.80
        static let pane = 0.80
        static let hud = 0.78
    }

    static let minHitTarget: CGFloat = 44
    static let cardRadius = 16.0
    static let compactRadius = 10.0
    static let pagePadding = 18.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0

    private static func composite(
        _ top: (Double, Double, Double), _ alpha: Double, over bottom: (Double, Double, Double)
    ) -> Color {
        Color(.sRGB,
              red: (top.0 * alpha + bottom.0 * (1 - alpha)).rounded() / 255,
              green: (top.1 * alpha + bottom.1 * (1 - alpha)).rounded() / 255,
              blue: (top.2 * alpha + bottom.2 * (1 - alpha)).rounded() / 255,
              opacity: 1)
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xff) / 255,
              green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255, opacity: 1)
    }
}
