import SwiftUI

struct FirstMateStatusLabel: View {
    let status: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Label(title, systemImage: symbol)
            .herdrFont(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.09), in: .rect(cornerRadius: 6))
            .accessibilityLabel(title)
    }
    private var title: String {
        switch status {
        case "awaiting_direction": "Your direction"
        case "running", "coordinating": "Working"
        case "completed", "complete": "Complete"
        case "ready": "Ready to plan"
        case "recovering": "Recovering"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private var symbol: String {
        switch status {
        case "awaiting_direction", "blocked", "recovering": "hand.raised"
        case "unverified": "exclamationmark.triangle"
        case "running", "coordinating": "arrow.trianglehead.2.clockwise.rotate.90"
        case "completed", "complete", "passed": "checkmark.circle"
        case "paused": "pause.circle"
        case "cancelled", "failed", "error": "exclamationmark.circle"
        default: "circle"
        }
    }
    private var color: Color {
        switch status {
        case "awaiting_direction", "blocked", "paused", "recovering", "unverified": scheme == .light ? Color(red: 0.58, green: 0.39, blue: 0.09) : .orange
        case "completed", "complete", "passed": scheme == .light ? Color(red: 0.14, green: 0.49, blue: 0.40) : .green
        case "failed", "error": .red
        default: .secondary
        }
    }
}
