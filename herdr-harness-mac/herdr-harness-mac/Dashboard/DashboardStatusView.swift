import SwiftUI

struct DashboardStatusView: View {
    let status: String
    private var label: String {
        switch status {
        case "awaiting_direction": "Your direction"
        case "blocked": "Blocked"
        case "running", "coordinating": "Working"
        case "recovering": "Recovering"
        case "ready": "Ready to plan"
        case "paused": "Paused"
        case "completed", "finished": "Finished"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    private var symbol: String {
        switch status {
        case "awaiting_direction": "diamond.fill"
        case "blocked", "failed": "exclamationmark.triangle.fill"
        case "running", "coordinating", "recovering": "circle.lefthalf.filled"
        case "completed", "finished": "checkmark.circle"
        case "paused": "pause.fill"
        default: "circle"
        }
    }
    private var color: Color {
        if FirstMateAttention.needsHumanDecision(status: status) { return HerdrTheme.working }
        if ["running", "coordinating", "recovering"].contains(status) { return HerdrTheme.signal }
        return HerdrTheme.mist
    }
    var body: some View {
        Label(label, systemImage: symbol)
            .herdrFont(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.08), in: .rect(cornerRadius: 5))
            .accessibilityElement(children: .combine)
    }
}
