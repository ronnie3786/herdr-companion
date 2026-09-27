import SwiftUI

struct FirstMatePalette {
    var scheme: ColorScheme

#if os(macOS)
    // Mono × Herdr on the Mac: MonoCode's two-color generator. Dark matches the
    // app's `HerdrTheme`; light is MonoCode's light theme (base 97%, ink 18%)
    // with text lifted to 88% / 82% / 76% so every level clears 4.5:1.
    private static let darkBase = rgb(0x15, 0x15, 0x19)
    private static let darkInk = rgb(0xE9, 0xE9, 0xEC)
    private static let lightBase = rgb(0xF7, 0xF7, 0xF8)
    private static let lightInk = rgb(0x2A, 0x2A, 0x32)

    private var isDark: Bool { scheme == .dark }
    private var ink: Color { isDark ? Self.darkInk : Self.lightInk }

    var background: Color { isDark ? Self.darkBase : Self.lightBase }
    /// Dark: the base darkened by 10%. Light: MonoCode's light rail is the base.
    var sidebar: Color { isDark ? Self.rgb(0x13, 0x13, 0x17) : Self.lightBase }
    /// Opaque raised surface: ink at 5% over the base.
    var surface: Color { isDark ? Self.rgb(0x20, 0x20, 0x24) : Self.rgb(0xED, 0xED, 0xEE) }
    var accent: Color { isDark ? Self.rgb(0xAA, 0xA6, 0xF4) : Self.rgb(0x61, 0x52, 0xB3) }
    var text: Color { ink }
    /// Labels: ink 70% (dark) / 82% (light) over the base.
    var secondaryText: Color { isDark ? Self.rgb(0xA9, 0xA9, 0xAD) : Self.rgb(0x4F, 0x4F, 0x56) }
    /// Metadata: ink 70% / 76%. Dark matches secondary so it reads at 4.5:1
    /// over the dusk glass, as `HerdrTheme.tertiaryText` does.
    var tertiaryText: Color { isDark ? Self.rgb(0xA9, 0xA9, 0xAD) : Self.rgb(0x5B, 0x5B, 0x62) }
    /// Rendered prose: ink 78% / 88%.
    var proseText: Color { isDark ? Self.rgb(0xBA, 0xBA, 0xBE) : Self.rgb(0x43, 0x43, 0x4A) }
    /// Glyph-only icons: ink 50% / 62%.
    var iconTint: Color { isDark ? Self.rgb(0x7F, 0x7F, 0x83) : Self.rgb(0x78, 0x78, 0x7D) }
    var line: Color { ink.opacity(0.10) }
    var hairline: Color { ink.opacity(0.07) }
    var rowDivider: Color { ink.opacity(0.05) }
    var cardFill: Color { ink.opacity(0.03) }
    var insetFill: Color { ink.opacity(0.05) }
    var chipFill: Color { ink.opacity(0.08) }
    var hoverFill: Color { ink.opacity(isDark ? 0.05 : 0.04) }
    var selectedFill: Color { ink.opacity(isDark ? 0.10 : 0.06) }
    /// The user's message bubble.
    var bubbleFill: Color { ink.opacity(isDark ? 0.10 : 0.08) }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
#else
    var background: Color { scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(red: 0.99, green: 0.99, blue: 1) }
    var sidebar: Color { scheme == .dark ? Color(red: 0.075, green: 0.085, blue: 0.12) : Color(red: 0.95, green: 0.955, blue: 0.975) }
    var surface: Color { scheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.20) : Color(red: 0.955, green: 0.96, blue: 0.975) }
    var accent: Color { scheme == .dark ? Color(red: 0.70, green: 0.67, blue: 1) : Color(red: 0.38, green: 0.32, blue: 0.70) }
    var text: Color { scheme == .dark ? Color(red: 0.91, green: 0.92, blue: 0.97) : Color(red: 0.12, green: 0.14, blue: 0.20) }
    var secondaryText: Color { scheme == .dark ? Color(red: 0.68, green: 0.71, blue: 0.80) : Color(red: 0.35, green: 0.38, blue: 0.47) }
    var line: Color { text.opacity(0.12) }
#endif
}
