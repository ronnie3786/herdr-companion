import SwiftUI

/// Same paper colors as Mac HUD notes, always paired with dark readable ink.
enum RemoteNoteColor: String, CaseIterable, Sendable {
    case yellow, peach, pink, green, blue, lavender

    var fill: Color {
        switch self {
        case .yellow: Color(red: 0.9765, green: 0.8863, blue: 0.6863)
        case .peach: Color(red: 0.9804, green: 0.7020, blue: 0.5294)
        case .pink: Color(red: 0.9608, green: 0.7608, blue: 0.9059)
        case .green: Color(red: 0.6510, green: 0.8902, blue: 0.6314)
        case .blue: Color(red: 0.5373, green: 0.7059, blue: 0.9804)
        case .lavender: Color(red: 0.7059, green: 0.7451, blue: 0.9961)
        }
    }
}
