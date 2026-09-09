import AppKit
import SwiftUI
import os

enum HerdrTheme {
    // Comfortable reading: one palette for native chrome and embedded web views.
    static let ink = color(0x191A23)
    static let graphite = color(0x20212C)
    static let elevated = color(0x292B39)
    static let input = color(0x2B2D3B)
    static let surface = color(0x353747)
    static let separator = color(0x343643)
    static let subtleSeparator = color(0x2C2E3A)
    static let selection = color(0x353649)
    static let mist = color(0xB3B5C6)
    static let muted = color(0xA0A3B4)
    static let text = color(0xE4E5ED)
    static let accent = color(0xAAA6F4)
    // Native filled controls retain white labels on macOS, so their lavender
    // fill is deeper than the accent used for links and custom ink-label CTAs.
    static let controlAccent = color(0x625DAD)
    static let primaryAction = color(0xA6BAFF)
    static let mauve = color(0xB9A7DF)
    static let signal = color(0x9CCDB9)
    static let success = color(0xA3CBA7)
    static let working = color(0xE4C386)
    static let alert = color(0xE2A7B6)
    static let diffAdd = color(0x83BC91)
    static let diffRemove = color(0xD997A2)
    static let diffHunk = color(0xA6BAFF)
    static let warning = color(0xDFB38E)
    static let code = color(0xCFB8E8)
    static let crust = color(0x15161E)

    static let cardRadius = 12.0
    static let compactRadius = 8.0
    static let pagePadding = 24.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0
    static let readingWidth = 980.0
    static let transcriptGutter = 36.0

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
    /// 28pt, not iOS's 44pt: Mac chrome is deliberately compact (see
    /// `PiChatChrome.controlHeight` and `ComposerDeckMetrics.controlHeight`,
    /// both 30). This is the floor, not the target — nothing interactive may be
    /// smaller than the glyph the pointer is aiming at.
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
