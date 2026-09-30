import SwiftUI

struct FirstMateStatusLabel: View {
    let status: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.1), in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(title)
    }

    private var title: String {
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

    private var symbol: String {
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

    private var color: Color {
        switch status {
        case "awaiting_direction", "blocked", "paused", "recovering":
            HerdrTheme.warning
        case "completed", "complete", "passed":
            HerdrTheme.success
        case "failed", "error": HerdrTheme.alert
        case "running", "coordinating", "waiting_children": HerdrTheme.accent
        default: HerdrTheme.secondaryText
        }
    }
}
