import SwiftUI

/// The three First Mate status colors that reuse the agent session HUD's
/// semantic palette: blocked is red, waiting on your direction is green, and
/// working is yellow.
///
/// The dark appearance returns the HUD tokens themselves, so First Mate and
/// the session bubbles match exactly. First Mate also offers a light
/// appearance, where those pale tokens lose contrast against a light surface,
/// so the same hues are deepened there. Unrelated statuses are absent by
/// design: callers keep their existing treatment for everything this mapping
/// does not name.
enum FirstMateStatusColors {
    enum Kind: CaseIterable, Equatable {
        case blocked
        case awaitingDirection
        case working
    }

    /// Only the requested raw statuses map to a HUD color. Every other value
    /// returns nil so unknown and unrelated statuses keep their fallbacks.
    static func kind(for status: String) -> Kind? {
        switch status {
        case "blocked": .blocked
        case "awaiting_direction": .awaitingDirection
        case "running", "coordinating": .working
        default: nil
        }
    }

    /// The shared agent HUD token for `kind`; the dark appearance returns it
    /// unchanged and the global palette is never modified.
    static func hudColor(for kind: Kind) -> Color {
        switch kind {
        case .blocked: HerdrTheme.alert
        case .awaitingDirection: HerdrTheme.signal
        case .working: HerdrTheme.working
        }
    }

    static func color(for status: String, scheme: ColorScheme) -> Color? {
        kind(for: status).map { color(for: $0, scheme: scheme) }
    }

    static func color(for kind: Kind, scheme: ColorScheme) -> Color {
        scheme == .light ? lightColor(for: kind) : hudColor(for: kind)
    }

    /// Each light color keeps its HUD token's hue and deepens it until the
    /// normal-weight caption and its icon clear the repository's 4.5:1
    /// text-contrast floor on a badge's 9% color wash over every First Mate
    /// light surface (the Dashboard pill's 12% wash was checked as well).
    private static func lightColor(for kind: Kind) -> Color {
        switch kind {
        case .blocked:
            Color(.sRGB, red: 166 / 255, green: 33 / 255, blue: 67 / 255, opacity: 1) // #A62143
        case .awaitingDirection:
            Color(.sRGB, red: 31 / 255, green: 102 / 255, blue: 73 / 255, opacity: 1) // #1F6649
        case .working:
            Color(.sRGB, red: 128 / 255, green: 83 / 255, blue: 0, opacity: 1) // #805300
        }
    }
}
