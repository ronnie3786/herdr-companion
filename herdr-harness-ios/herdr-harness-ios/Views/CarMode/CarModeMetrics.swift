import SwiftUI

/// Car mode sizes. A driving UI keeps its touch targets predictable, so Dynamic
/// Type scales the type and the targets together but clamps instead of growing
/// without limit; the grid scrolls rather than shrinking a target below this.
enum CarModeMetrics {
    static let minimumActionHeight: CGFloat = 60
    static let actionHeight: CGFloat = 64
    static let landscapeActionHeight: CGFloat = 60
    static let micHeight: CGFloat = 96
    static let exitSize: CGFloat = 54
    static let backSize: CGFloat = 54
    static let portraitCardMinHeight: CGFloat = 170
    static let landscapeRowMinHeight: CGFloat = 72
    static let cardSpacing: CGFloat = 9
    static let pagePadding: CGFloat = 16

    static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small: 0.94
        case .medium, .large: 1
        case .xLarge: 1.04
        case .xxLarge: 1.08
        case .xxxLarge: 1.12
        default: 1.16
        }
    }

    static func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
        (value * scale).rounded()
    }
}
/// The status chip shared by the card, the detail header, and the voice layer.
/// The symbol changes with the status as well as the color, so a glance works
/// without relying on color alone.
struct CarStatusChip: View {
    let status: AgentStatus
    let scale: CGFloat

    var body: some View {
        HStack(spacing: CarModeMetrics.scaled(6, by: scale)) {
            Image(systemName: status.symbol)
                .font(.system(size: 13 * scale, weight: .bold))
            Text(status.compactTitle)
                .font(.system(size: 14.5 * scale, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, CarModeMetrics.scaled(10, by: scale))
        .padding(.vertical, CarModeMetrics.scaled(5, by: scale))
        .background(tint.opacity(0.15), in: .capsule)
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
    }

    private var tint: Color {
        SidebarRowTone.statusColor(for: status)
    }
}

/// The summary-audio control. Mirrors the chat composer's wording and phases,
/// but sized for a dashboard: never smaller than `minimumActionHeight`.
struct CarAudioButton: View {
    let entry: CarModeStore.Entry
    let action: ResponseAudioAction
    let scale: CGFloat
    let isWide: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: CarModeMetrics.scaled(8, by: scale)) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 19 * scale, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 16.5 * scale, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(HerdrTheme.mauve, in: .rect(cornerRadius: radius))
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("car-audio-\(entry.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .composerLayoutMeasurement(id: "car-audio-\(entry.id)", label: accessibilityLabel)
    }

    private var height: CGFloat {
        CarModeMetrics.scaled(isWide ? CarModeMetrics.landscapeActionHeight : CarModeMetrics.actionHeight, by: scale)
    }

    private var radius: CGFloat {
        CarModeMetrics.scaled(isWide ? 15 : 17, by: scale)
    }

    private var phase: ResponseAudioPlaybackPhase { entry.audioPlayer.phase }

    private var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    /// Ink-colored text and icons on the mauve, amber, and signal fills.
    private var foreground: Color { HerdrTheme.input }

    /// Enabled whenever there is an answer to summarize, unless this machine has
    /// already told us summary audio is not configured.
    private var isEnabled: Bool {
        guard entry.summary.hasPlayableResponse else { return false }
        if entry.didLoadAudioCapabilities, !entry.audioPlayer.capabilities.available { return false }
        return true
    }

    private var title: String {
        switch phase {
        case .preparing: "Preparing"
        case .playing: "Pause"
        case .paused: "Resume"
        case .unavailable, .checking, .idle: action.title
        }
    }

    private var systemImage: String {
        switch phase {
        case .preparing: "stop.circle.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        case .unavailable, .checking, .idle: action.systemImage
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .preparing: "Stop preparing the summary for \(entry.session.pane.displayTitle)"
        case .playing: "Pause the summary for \(entry.session.pane.displayTitle)"
        case .paused: "Resume the summary for \(entry.session.pane.displayTitle)"
        case .unavailable, .checking, .idle:
            entry.summary.hasPlayableResponse
                ? "Play the summary of \(entry.session.pane.displayTitle)"
                : "No summary audio yet for \(entry.session.pane.displayTitle)"
        }
    }

    private var accessibilityHint: String {
        if entry.didLoadAudioCapabilities, !entry.audioPlayer.capabilities.available {
            return "Summary audio is not configured on this machine"
        }
        return "Speaks the newest answer"
    }
}

/// The oversized voice-reply control.
struct CarReplyButton: View {
    let entry: CarModeStore.Entry
    let scale: CGFloat
    let isWide: Bool
    let isRecording: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: CarModeMetrics.scaled(8, by: scale)) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20 * scale, weight: .bold))
                Text(isRecording ? "Done" : "Respond")
                    .font(.system(size: 16.5 * scale, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(HerdrTheme.input)
            .frame(maxWidth: .infinity)
            .frame(height: CarModeMetrics.scaled(
                isWide ? CarModeMetrics.landscapeActionHeight : CarModeMetrics.actionHeight,
                by: scale
            ))
            .background(isRecording ? HerdrTheme.alert : HerdrTheme.accent, in: .rect(cornerRadius: CarModeMetrics.scaled(isWide ? 15 : 17, by: scale)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("car-reply-\(entry.id)")
        .accessibilityLabel(isRecording ? "Finish recording a reply for \(entry.session.pane.displayTitle)" : "Reply to \(entry.session.pane.displayTitle) by voice")
        .accessibilityHint("Car mode replies are spoken, never typed")
        .composerLayoutMeasurement(id: "car-reply-\(entry.id)", label: "Respond")
    }
}
