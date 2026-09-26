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
/// The Mac app is dark everywhere except First Mate's light appearance. The
/// neutral, accent and status roles follow the view's color scheme there,
/// resolving to MonoCode light (base hsl(240 8% 97%), ink hsl(240 8% 18%)), so
/// shared chrome such as the composer and title bar works on both. Code
/// colors (diff, syntax) stay dark. Outside a view, `resolved(_:scheme:)`
/// picks an appearance explicitly.
///
/// Older names (`graphite`, `elevated`, `mist`, …) remain as aliases of these
/// roles so every view reads as the new palette; components adopt the role
/// names and recipes in `HerdrRecipes.swift` as they are restyled.
enum HerdrTheme {
    // MARK: Generator

    /// hsl(240 8% 9%), #151519 (light: hsl(240 8% 97%), #F7F7F8). The pane and
    /// window background.
    static let base = adaptive(dark: baseRGB, light: lightBaseRGB)
    /// hsl(240 8% 92%), #E9E9EC (light: hsl(240 8% 18%), #2A2A32). Primary
    /// text; every neutral fill is this at an alpha.
    static let foreground = adaptive(dark: foregroundRGB, light: lightForegroundRGB)

    /// `foreground` at `alpha`: translucent, for fills and lines that sit on
    /// any surface (including glass).
    static func inkFill(_ alpha: Double) -> Color {
        foreground.opacity(alpha)
    }

    /// `foreground` at `alpha` composited over `base`: opaque, for text and for
    /// surfaces that must hide what is behind them.
    static func inkSolid(_ alpha: Double) -> Color {
        inkSolid(dark: alpha, light: alpha)
    }

    // MARK: Surfaces

    static let windowBackground = base
    /// The sidebar rail: `base` darkened by 10%, #131317. Light rails are base.
    static let railBackground = adaptive(dark: blend((0, 0, 0), 0.10, over: baseRGB), light: lightBaseRGB)

    // MARK: Fills (translucent)

    /// Cards, the composer and folder groups.
    static let cardFill = inkFill(0.03)
    static let fieldFill = inkFill(0.04)
    /// Inset blocks inside cards (NOW, hunk bars) and hovered rows.
    static let insetFill = inkFill(0.05)
    static let hoverFill = inkFill(dark: 0.05, light: 0.04)
    static let codeFill = inkFill(0.06)
    /// Inline code chips and document chips.
    static let chipFill = inkFill(0.08)
    /// Selected rows, tabs and pills, and the user's message bubble.
    static let selectedFill = inkFill(dark: 0.10, light: 0.06)

    // MARK: Lines (translucent)

    /// Title bar, sidebar and section rules. Increase Contrast draws every
    /// rule at 16%.
    static let hairline = line(0.07)
    static let rowDivider = line(0.05)
    /// Card, field and composer outlines.
    static let outline = line(0.10)
    static let strongOutline = inkFill(0.15)
    static let focusOutline = inkFill(0.20)

    // MARK: Text (opaque)

    static let primaryText = foreground
    /// Rendered prose: 78% (light 88%).
    static let proseText = inkSolid(dark: 0.78, light: 0.88)
    /// Labels and secondary copy: 70% (light 82%).
    static let secondaryText = inkSolid(dark: 0.70, light: 0.82)
    /// Metadata, timestamps and placeholders: 64% (light 76%), the lowest text
    /// level. Increase Contrast lifts it to the secondary level.
    static let tertiaryText = inkSolid(dark: 0.64, light: 0.76, highContrastDark: 0.70, highContrastLight: 0.82)
    /// Glyph-only icons: 50% (light 62%). Never use for words.
    static let iconTint = inkSolid(dark: 0.50, light: 0.62)

    // MARK: Accent and actions

    static let accent = adaptive(dark: 0xAAA6F4, light: 0x6152B3)
    /// Custom primary buttons (send, Agent view): lavender with a dark label
    /// (deep lavender with a white label in light).
    static let primaryAction = accent
    static let onPrimary = adaptive(dark: baseRGB, light: (255, 255, 255))
    static let primaryDisabled = accent.opacity(0.28)
    static let onPrimaryDisabled = adaptive(dark: baseRGB, light: (255, 255, 255), darkAlpha: 0.55, lightAlpha: 0.85)
    // Native filled controls retain white labels on macOS, so their lavender
    // fill is deeper than the accent used for links and custom ink-label CTAs.
    static let controlAccent = adaptive(dark: 0x5E59A8, light: 0x6152B3)
    /// Count badges (Git sections): lavender at 85% with a dark label.
    static let badgeFill = accent.opacity(0.85)
    static let onBadge = onPrimary
    /// The First Mate row's attention badge.
    static let attentionBadge = color(0xFF9F0A)
    static let onAttentionBadge = color(0x1A1A1A)
    /// Folder glyphs in the sidebar.
    static let folder = color(0xB9A7DF)
    /// The first bar of the brand mark and the blue note color.
    static let brandBlue = color(0xA6BAFF)

    // MARK: Status (Herdr's pastels; light uses First Mate's deepened hues)

    static let signal = adaptive(dark: 0x9CCDB9, light: 0x1F6649)
    static let success = adaptive(dark: 0xA3CBA7, light: 0x1C6B56)
    static let working = adaptive(dark: 0xE4C386, light: 0x805300)
    static let alert = adaptive(dark: 0xE2A7B6, light: 0xA62143)
    static let warning = adaptive(dark: 0xDFB38E, light: 0x7A4E0E)

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
    private static let lightBaseRGB = hslComponents(240, 8, 97)
    private static let lightForegroundRGB = hslComponents(240, 8, 18)

    /// Mirrors System Settings → Accessibility → Increase Contrast, read by
    /// the roles' providers wherever they resolve.
    fileprivate static let increasedContrast = OSAllocatedUnfairLock(initialState: false)
    @MainActor private static var contrastObserver: NSObjectProtocol?

    /// Starts following Increase Contrast. Called once at launch.
    @MainActor static func followAccessibilityContrast() {
        guard contrastObserver == nil else { return }
        let update = { @MainActor in
            let value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            increasedContrast.withLock { $0 = value }
        }
        update()
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { update() } }
    }

    /// `color` as sRGB under a given appearance. Views resolve roles from
    /// their color scheme; code outside a view (web themes, tests) uses this
    /// so the result never depends on the system appearance.
    static func resolved(_ color: Color, scheme: ColorScheme = .dark) -> NSColor {
        let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua) ?? NSAppearance.currentDrawing()
        var result = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return result
    }

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

    private static func blend(_ top: RGB, _ alpha: Double, over bottom: RGB) -> RGB {
        (
            (top.0 * alpha + bottom.0 * (1 - alpha)).rounded(),
            (top.1 * alpha + bottom.1 * (1 - alpha)).rounded(),
            (top.2 * alpha + bottom.2 * (1 - alpha)).rounded()
        )
    }

    private static func composite(_ top: RGB, _ alpha: Double, over bottom: RGB) -> Color {
        rgbColor(blend(top, alpha, over: bottom))
    }

    /// Ink composited over base, at its own alpha in each scheme (and,
    /// optionally, a higher alpha under Increase Contrast).
    private static func inkSolid(dark: Double, light: Double, highContrastDark: Double? = nil, highContrastLight: Double? = nil) -> Color {
        let darkColor = nsColor(blend(foregroundRGB, dark, over: baseRGB), alpha: 1)
        let lightColor = nsColor(blend(lightForegroundRGB, light, over: lightBaseRGB), alpha: 1)
        let darkContrast = nsColor(blend(foregroundRGB, highContrastDark ?? dark, over: baseRGB), alpha: 1)
        let lightContrast = nsColor(blend(lightForegroundRGB, highContrastLight ?? light, over: lightBaseRGB), alpha: 1)
        return variant { $0.pick(dark: darkColor, light: lightColor, darkContrast: darkContrast, lightContrast: lightContrast) }
    }

    /// A translucent rule: ink at `alpha`, or 16% under Increase Contrast.
    private static func line(_ alpha: Double) -> Color {
        let dark = nsColor(foregroundRGB, alpha: alpha), light = nsColor(lightForegroundRGB, alpha: alpha)
        let darkContrast = nsColor(foregroundRGB, alpha: 0.16), lightContrast = nsColor(lightForegroundRGB, alpha: 0.16)
        return variant { $0.pick(dark: dark, light: light, darkContrast: darkContrast, lightContrast: lightContrast) }
    }

    /// The appearance a role resolves under.
    private enum Variant: Sendable {
        case dark, light, darkContrast, lightContrast

        init(_ appearance: NSAppearance) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let light = match == .aqua || match == .accessibilityHighContrastAqua
            let contrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                || HerdrTheme.increasedContrast.withLock { $0 }
            switch (light, contrast) {
            case (true, false): self = .light
            case (true, true): self = .lightContrast
            case (false, true): self = .darkContrast
            case (false, false): self = .dark
            }
        }

        func pick(dark: NSColor, light: NSColor, darkContrast: NSColor, lightContrast: NSColor) -> NSColor {
            switch self {
            case .dark: dark
            case .light: light
            case .darkContrast: darkContrast
            case .lightContrast: lightContrast
            }
        }
    }

    private static func variant(_ provider: @escaping @Sendable (Variant) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { provider(Variant($0)) })
    }

    /// Translucent ink at its own alpha in each scheme.
    private static func inkFill(dark: Double, light: Double) -> Color {
        adaptive(dark: foregroundRGB, light: lightForegroundRGB, darkAlpha: dark, lightAlpha: light)
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        adaptive(dark: components(dark), light: components(light))
    }

    /// A role that follows the resolving appearance: light for Aqua, dark for
    /// everything else (Dark Aqua and the vibrant and high-contrast variants).
    private static func adaptive(dark: RGB, light: RGB, darkAlpha: Double = 1, lightAlpha: Double = 1) -> Color {
        let darkColor = nsColor(dark, alpha: darkAlpha)
        let lightColor = nsColor(light, alpha: lightAlpha)
        return variant { $0 == .light || $0 == .lightContrast ? lightColor : darkColor }
    }

    private static func nsColor(_ rgb: RGB, alpha: Double) -> NSColor {
        NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: alpha)
    }

    private static func components(_ rgb: UInt32) -> RGB {
        (Double((rgb >> 16) & 0xff), Double((rgb >> 8) & 0xff), Double(rgb & 0xff))
    }

    private static func rgbColor(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, opacity: 1)
    }

    private static func color(_ rgb: UInt32) -> Color {
        rgbColor(components(rgb))
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

    /// A text style on MonoCode's ramp, scaled by the user's text size. Views
    /// use this through `herdrFont(_:)`: meta text (caption, footnote) reads
    /// at 11 rather than AppKit's 10, which MonoCode keeps for uppercase
    /// micro labels. The terminal keeps AppKit's sizes through `scaled`.
    static func rampScaled(
        _ style: Font.TextStyle,
        scale: HerdrFontScale,
        monospaced: Bool = false,
        weight: Font.Weight? = nil
    ) -> Font {
        let key = ScaledFontKey(style: style, scale: -scale.rawValue, monospaced: monospaced, weight: weight)
        if let cached = scaledFontCache.withLock({ $0[key] }) {
            return cached
        }
        let (size, defaultWeight) = rampSize(style)
        let font: Font = .system(
            size: size * scale.rawValue,
            weight: weight ?? defaultWeight,
            design: monospaced ? .monospaced : .default
        )
        scaledFontCache.withLock { $0[key] = font }
        return font
    }

    /// MonoCode's size for a text style at 100%.
    static func rampSize(_ style: Font.TextStyle) -> (CGFloat, Font.Weight) {
        switch style {
        case .largeTitle: (22, .semibold)
        case .title, .title2: (TextSize.title, .semibold)
        case .title3: (TextSize.reading, .regular)
        case .headline: (TextSize.body, .semibold)
        case .body: (TextSize.body, .regular)
        case .callout, .subheadline: (TextSize.small, .regular)
        default: (TextSize.caption, .regular)
        }
    }

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
