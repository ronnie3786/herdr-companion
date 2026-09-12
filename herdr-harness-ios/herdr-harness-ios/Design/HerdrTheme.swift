import SwiftUI

enum HerdrTheme {
    // Comfortable reading: the Mac charcoal/lavender palette with iOS layout metrics.
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

    static let cardRadius = 16.0
    static let compactRadius = 10.0
    static let pagePadding = 18.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}
