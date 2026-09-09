import SwiftUI

enum HerdPulseTheme {
    static let ink = HerdrTheme.ink
    static let graphite = HerdrTheme.graphite
    static let elevated = HerdrTheme.elevated
    static let mist = HerdrTheme.mist
    static let text = HerdrTheme.text
    static let accent = HerdrTheme.accent
    static let signal = HerdrTheme.signal
    static let working = HerdrTheme.working
    static let alert = HerdrTheme.alert

    static func color(for phase: HerdPulsePhase) -> Color {
        switch phase {
        case .attention: alert
        case .ready: signal
        case .working: working
        case .resting: accent
        case .offline: mist
        }
    }
}
