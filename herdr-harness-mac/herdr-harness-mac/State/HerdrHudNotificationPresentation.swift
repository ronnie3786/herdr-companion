import SwiftUI

/// Chooses the collapsed HUD orb's notification outline without changing which
/// notifications are visible. Blocked and failed work remains an alert; a set
/// containing only finished work uses the existing green completion signal.
enum HerdrHudNotificationPresentation {
    enum Tone: Equatable {
        case finished
        case alert
    }

    enum UltraCompactTone: Equatable {
        case working
        case finished
        case alert
        case idle
        case offline
    }

    static func tone(for statuses: [AgentStatus], fallbackCount: Int = 0) -> Tone? {
        if statuses.contains(.blocked) { return .alert }
        if !statuses.isEmpty {
            return statuses.allSatisfy { $0 == .done } ? .finished : .alert
        }
        return fallbackCount > 0 ? .finished : nil
    }

    static func ultraCompactTone(
        sessionIsRunning: Bool,
        workingCount: Int,
        statuses: [AgentStatus],
        fallbackAttentionCount: Int = 0,
        isConnected: Bool
    ) -> UltraCompactTone {
        if sessionIsRunning || workingCount > 0 || statuses.contains(.working) { return .working }
        if statuses.contains(.blocked) { return .alert }
        if !statuses.isEmpty {
            return statuses.allSatisfy { $0 == .done } ? .finished : .alert
        }
        if fallbackAttentionCount > 0 { return .finished }
        return isConnected ? .idle : .offline
    }

    static func ultraCompactColor(for tone: UltraCompactTone) -> Color {
        switch tone {
        case .working: HerdrTheme.working
        case .finished: HerdrTheme.signal
        case .alert: HerdrTheme.alert
        case .idle: HerdrTheme.accent
        case .offline: HerdrTheme.muted
        }
    }

    static func ultraCompactAccessibilityValue(for tone: UltraCompactTone) -> String {
        switch tone {
        case .working: "Working"
        case .finished: "Completed work is ready"
        case .alert: "Blocked or failed work needs attention"
        case .idle: "Idle"
        case .offline: "Offline"
        }
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
