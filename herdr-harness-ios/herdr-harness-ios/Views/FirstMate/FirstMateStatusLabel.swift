import SwiftUI

/// A status as a small glyph and word in the status color, the Mac's
/// inspector status (MonoCode's `.st`), never a filled capsule.
struct FirstMateStatusLabel: View {
    let status: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            Text(title)
        }
        .herdrFont(.footnote, weight: .medium)
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var title: String { Self.title(for: status) }
    private var symbol: String { Self.symbol(for: status) }
    private var color: Color { Self.color(for: status) }

    static func title(for status: String) -> String {
        switch status {
        case "awaiting_direction": "Your direction"
        case "running", "coordinating": "Working"
        case "completed", "complete": "Complete"
        case "ready": "Ready to plan"
        case "waiting_children": "Delegating"
        case "quiesced": "Handed off"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(for status: String) -> String {
        switch status {
        case "awaiting_direction", "blocked": "hand.raised"
        case "running", "coordinating", "recovering": "arrow.trianglehead.2.clockwise.rotate.90"
        case "waiting_children": "person.2"
        case "completed", "complete", "passed": "checkmark.circle"
        case "paused": "pause.circle"
        case "quiesced": "arrow.turn.down.right"
        case "cancelled", "failed", "error": "exclamationmark.circle"
        default: "circle"
        }
    }

    /// The Mac's HUD colors: blocked red, your direction green, working
    /// yellow; the remaining statuses keep their quieter fallbacks.
    static func color(for status: String) -> Color {
        switch status {
        case "blocked", "failed", "error": HerdrTheme.alert
        case "awaiting_direction": HerdrTheme.signal
        case "running", "coordinating": HerdrTheme.working
        case "paused", "recovering": HerdrTheme.warning
        case "completed", "complete", "passed": HerdrTheme.success
        case "waiting_children": HerdrTheme.accent
        default: HerdrTheme.secondaryText
        }
    }
}
