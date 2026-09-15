import SwiftUI

/// Chooses the collapsed HUD orb's notification outline without changing which
/// notifications are visible. Blocked and failed work remains an alert; a set
/// containing only finished work uses the existing green completion signal.
enum HerdrHudNotificationPresentation {
    enum Tone: Equatable {
        case finished
        case alert
    }

    static func tone(for statuses: [AgentStatus], fallbackCount: Int = 0) -> Tone? {
        if statuses.contains(.blocked) { return .alert }
        if !statuses.isEmpty {
            return statuses.allSatisfy { $0 == .done } ? .finished : .alert
        }
        return fallbackCount > 0 ? .finished : nil
    }

    static func status(forHUDChat runStatus: HeadlessAgentRunStatus?) -> AgentStatus {
        runStatus == .completed ? .done : .blocked
    }

    static func outlineColor(for status: AgentStatus) -> Color {
        status == .done ? HerdrTheme.signal : status.color
    }

    static func outlineColor(for tone: Tone) -> Color {
        switch tone {
        case .finished: HerdrTheme.signal
        case .alert: HerdrTheme.alert
        }
    }

    static func orbAccessibilityValue(
        sessionIsRunning: Bool,
        attentionCount: Int,
        workingCount: Int,
        isConnected: Bool
    ) -> String {
        if sessionIsRunning { return "Thinking" }
        if attentionCount > 0 { return "\(attentionCount) need attention" }
        if workingCount > 0 { return "Working" }
        return isConnected ? "Idle" : "Offline"
    }
}
