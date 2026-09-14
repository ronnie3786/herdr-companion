import SwiftUI

/// The small, semantic haptic vocabulary used throughout Herdr.
///
/// Keep this list tied to user intent. Live terminal frames and polling updates
/// must never emit feedback.
enum HerdrHaptic: Equatable, Sendable {
    case selection
    case terminalKey
    case controlsExpanded
    case controlsCollapsed
    case promptSent
    case gitStaged
    case gitUnstaged
    case recordingStarted
    case recordingLocked
    case recordingStopped
    case transcriptionStarted
    case transcriptionSucceeded
    case attention
    case stopped
    case completed
    case failed

    // macOS may render semantic success feedback as audio even when our
    // NSSound sink is silent. Sending a prompt must not request either channel.
    var feedback: SensoryFeedback? {
        switch self {
        case .selection:
            .selection
        case .terminalKey:
            .press(.buttonIconOnly)
        case .controlsExpanded:
            .selection(.on)
        case .controlsCollapsed:
            .selection(.off)
        case .promptSent:
            nil
        case .transcriptionSucceeded, .completed:
            .success
        case .gitStaged:
            .increase
        case .gitUnstaged:
            .decrease
        case .recordingStarted, .recordingLocked, .transcriptionStarted:
            .start
        case .recordingStopped, .stopped:
            .stop
        case .attention:
            .warning
        case .failed:
            .error
        }
    }
}
