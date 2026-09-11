import SwiftUI

/// Quiet, equal-weight accents over the existing charcoal/lavender surfaces.
/// Stable raw values are persisted locally; changing a display name is safe.
enum ChatTabColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case lavender, iris, rose, clay, sage, slate

    var id: String { rawValue }
    var defaultLabel: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .lavender: "1.circle.fill"
        case .iris: "2.circle.fill"
        case .rose: "3.circle.fill"
        case .clay: "4.circle.fill"
        case .sage: "5.circle.fill"
        case .slate: "6.circle.fill"
        }
    }

    var rgb: UInt32 {
        switch self {
        case .lavender: 0xB9A7DF
        case .iris: 0x969ED4
        case .rose: 0xCD9FAB
        case .clay: 0xC6AD96
        case .sage: 0x9DB9AE
        case .slate: 0x95B2C8
        }
    }

    var swatch: Color { blended(over: rgb, amount: 0) }
    var paneBackground: Color { blended(over: 0x20212C, amount: 0.12) }

    func rowBackground(selected: Bool = false, hovering: Bool = false) -> Color {
        blended(over: 0x191A23, amount: selected ? 0.20 : hovering ? 0.18 : 0.16)
    }

    /// Opaque fills keep contrast predictable regardless of the hosting view.
    private func blended(over base: UInt32, amount: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let background = Double((base >> shift) & 0xff)
            let accent = Double((rgb >> shift) & 0xff)
            return (background + (accent - background) * amount) / 255
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
}
