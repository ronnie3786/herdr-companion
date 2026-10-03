import SwiftUI

/// The locked First Mate Home palette. Values match the October 2026 reference.
enum HomePalette {
    static let base = color(0x151519)
    static let ink = color(0xE9E9EC)
    static let prose = color(0xBABABE)
    static let secondary = color(0xA9A9AD)
    static let icon = color(0x7F7F83)
    static let accent = color(0xAAA6F4)
    static let attention = color(0xFF9F0A)
    static let alert = color(0xE2A7B6)
    static let signal = color(0x9CCDB9)
    static let working = color(0xE4C386)
    static let idle = color(0x8E8E96)
    static let brandBlue = color(0xA6BAFF)
    static let hairline = ink.opacity(0.07)
    static let border = ink.opacity(0.10)
    static let accentWash = accent.opacity(0.10)
    static let accentLine = accent.opacity(0.38)

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    static func color(_ tone: HomeTone) -> Color {
        switch tone {
        case .accent: accent
        case .attention: attention
        case .alert: alert
        case .signal: signal
        case .working: working
        case .idle: idle
        case .brandBlue: brandBlue
        }
    }

    static func color(hex: String?) -> Color {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            return accent
        }
        return color(value)
    }
}
