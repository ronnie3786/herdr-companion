import SwiftUI

/// Presentation decisions for the collapsed HUD chat bubble.
///
/// The bubble deliberately copies the ordinary agent-session bubble: a healthy
/// run shows the same filled yellow bolt-circle "Running" row, the trailing
/// slot shows the same synchronized model/cumulative-cost metadata, and the
/// card keeps the same compact elevated chrome. Running status no longer adds
/// a working-only border or glow; the green unread Ready signal is the only
/// status-colored outline either surface keeps.
enum HerdrHudChatBubblePresentation {
    struct Status: Equatable {
        let label: String
        let symbol: String
        let color: Color
    }

    /// Everything the status row needs, separated from the session so every
    /// lifecycle state is directly testable without manufacturing a session.
    struct State: Equatable {
        var isEnding = false
        var isLoadingHistory = false
        var needsHistoryRefresh = false
        var isRunning = false
        var hasRunError = false
        var isPromoting = false
        var lastStatus: HeadlessAgentRunStatus?
        var hasUnseenAnswer = false
    }

    /// Matches `HerdrHudSessionBubbleLabel`'s compact elevated card.
    static let cornerRadius: CGFloat = 10
    static let horizontalPadding: CGFloat = 9
    static let verticalPadding: CGFloat = 6
    static let shadowRadius: CGFloat = 4

    static func status(_ state: State) -> Status {
        Status(label: label(state), symbol: symbol(state), color: color(state))
    }

    /// Building the state reads the main-actor session, so this convenience is
    /// main-actor isolated. The pure status policy above stays callable from
    /// any context that already holds a `State` value.
    @MainActor
    static func status(for session: HerdrHudSession) -> Status {
        status(State(session))
    }

    /// An unread Ready answer keeps its green signal; every other state,
    /// including a running one, uses the neutral separation outline.
    static func outlineColor(isReady: Bool) -> Color {
        isReady ? HerdrTheme.success : HerdrTheme.accent.opacity(0.45)
    }

    static func shadowColor(isReady: Bool) -> Color {
        isReady ? HerdrTheme.success.opacity(0.3) : .clear
    }

    /// Whether the collapsed bubble should advertise its unread completed
    /// answer. A run in flight is never "Ready".
    static func isReady(_ state: State) -> Bool {
        !state.isRunning && state.hasUnseenAnswer && state.lastStatus == .completed
    }

    private static func label(_ state: State) -> String {
        if state.isEnding { return "Ending…" }
        if state.isLoadingHistory { return "Loading…" }
        if state.needsHistoryRefresh { return "Reconnect to check status" }
        if state.isRunning { return state.hasRunError ? "Reconnecting…" : "Running" }
        if state.isPromoting { return "Continuing in agent…" }
        switch state.lastStatus {
        case .failed: return "Needs attention"
        case .cancelled: return "Stopped"
        case .promoted: return "In workspace"
        case .completed: return state.hasUnseenAnswer ? "Ready" : "Done"
        default: return "HUD chat"
        }
    }

    private static func symbol(_ state: State) -> String {
        if state.isEnding { return "stop.circle" }
        if state.isLoadingHistory { return "arrow.trianglehead.2.clockwise" }
        if state.needsHistoryRefresh { return "wifi.exclamationmark" }
        if state.isRunning {
            // The shared agent-session running glyph, so a healthy HUD run
            // reads as Running at a glance instead of via card chrome.
            return state.hasRunError ? "wifi.exclamationmark" : "bolt.circle.fill"
        }
        if state.isPromoting { return "arrow.up.forward.square" }
        switch state.lastStatus {
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .promoted: return "arrow.up.forward.square"
        default: return "checkmark.circle.fill"
        }
    }

    private static func color(_ state: State) -> Color {
        if state.isEnding { return HerdrTheme.mist }
        if state.isLoadingHistory || state.needsHistoryRefresh { return HerdrTheme.accent }
        if state.isRunning {
            // A poll failure during a run is connectivity trouble, never
            // confirmed progress.
            return state.hasRunError ? HerdrTheme.warning : AgentStatus.working.color
        }
        if state.isPromoting { return HerdrTheme.accent }
        if state.lastStatus == .failed { return HerdrTheme.alert }
        return state.hasUnseenAnswer && state.lastStatus == .completed
            ? HerdrTheme.success : HerdrTheme.mist
    }
}

@MainActor
extension HerdrHudChatBubblePresentation.State {
    init(_ session: HerdrHudSession) {
        self.init(
            isEnding: session.isEnding,
            isLoadingHistory: session.isLoadingHistory,
            needsHistoryRefresh: session.needsHistoryRefresh,
            isRunning: session.isRunning,
            hasRunError: session.errorMessage != nil,
            isPromoting: !session.promotingExchangeIDs.isEmpty,
            lastStatus: session.exchanges.last?.status,
            hasUnseenAnswer: session.hasUnseenAnswer
        )
    }
}
