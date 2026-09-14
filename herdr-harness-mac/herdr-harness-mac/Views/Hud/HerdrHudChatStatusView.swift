import SwiftUI

/// Text and symbols accompany color so readiness never depends on green alone.
struct HerdrHudChatStatusView: View {
    let session: HerdrHudSession

    var body: some View {
        Label(label, systemImage: symbol)
            .herdrFont(.caption2, weight: .medium)
            .foregroundStyle(color)
    }

    private var label: String {
        if session.isEnding { return "Ending…" }
        if session.isLoadingHistory { return "Loading…" }
        if session.needsHistoryRefresh { return "Reconnect to check status" }
        if session.isRunning { return session.errorMessage == nil ? "Running" : "Reconnecting…" }
        if !session.promotingExchangeIDs.isEmpty { return "Continuing in agent…" }
        switch session.exchanges.last?.status {
        case .failed: return "Needs attention"
        case .cancelled: return "Stopped"
        case .promoted: return "In workspace"
        case .completed: return session.hasUnseenAnswer ? "Ready" : "Done"
        default: return "HUD chat"
        }
    }

    private var symbol: String {
        if session.isEnding { return "stop.circle" }
        if session.isLoadingHistory { return "arrow.trianglehead.2.clockwise" }
        if session.needsHistoryRefresh { return "wifi.exclamationmark" }
        if session.isRunning { return "circle.dotted" }
        switch session.exchanges.last?.status {
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .promoted: return "arrow.up.forward.square"
        default: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        if session.isRunning || session.isLoadingHistory || session.needsHistoryRefresh { return HerdrTheme.accent }
        if session.exchanges.last?.status == .failed { return HerdrTheme.alert }
        return session.hasUnseenAnswer && session.exchanges.last?.status == .completed
            ? HerdrTheme.success : HerdrTheme.mist
    }
}
