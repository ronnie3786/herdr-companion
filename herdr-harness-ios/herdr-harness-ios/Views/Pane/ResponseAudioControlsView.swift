import SwiftUI

struct ResponseAudioControlsView: View {
    let player: ResponseAudioPlayer
    let activate: (ResponseAudioAction) -> Void

    var body: some View {
        if player.isVisible {
            HStack(spacing: 4) {
                ForEach(ResponseAudioAction.allCases) { action in
                    if player.capabilities.supports(action) {
                        ResponseAudioButton(
                            action: action,
                            phase: player.phase,
                            progressText: player.progressText,
                            activate: { activate(action) }
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ResponseAudioButton: View {
    let action: ResponseAudioAction
    let phase: ResponseAudioPlaybackPhase
    let progressText: String?
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            Group {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .accessibilityHidden(true)
                        .composerLayoutMeasurement(
                            id: "pi-response-audio-\(action.rawValue)-glyph",
                            label: "progress"
                        )
                } else {
                    Label(accessibilityLabel, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(isActive ? .medium : .regular))
                        .accessibilityHidden(true)
                        .composerLayoutMeasurement(
                            id: "pi-response-audio-\(action.rawValue)-glyph",
                            label: systemImage
                        )
                }
            }
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.38 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityValue(accessibilityValue)
        .composerLayoutMeasurement(
            id: "pi-response-audio-\(action.rawValue)",
            label: accessibilityLabel
        )
    }

    private var activeAction: ResponseAudioAction? { phase.activeAction }
    private var isActive: Bool { activeAction == action }
    private var isDisabled: Bool { activeAction != nil && !isActive }
    private var isPreparing: Bool {
        if case let .preparing(activeAction) = phase { return activeAction == action }
        return false
    }

    private var systemImage: String {
        guard isActive else { return action.systemImage }
        return switch phase {
        case .playing: "pause.fill"
        case .paused: "play.fill"
        case .preparing, .unavailable, .checking, .idle: action.systemImage
        }
    }

    private var tint: Color {
        if isActive { return phase == .paused(action) ? HerdrTheme.signal : HerdrTheme.working }
        return action == .listen ? HerdrTheme.accent : HerdrTheme.mauve
    }

    private var accessibilityLabel: String {
        guard isActive else { return action == .listen ? "Listen to response" : "Listen to response summary" }
        return switch phase {
        case .preparing: "Stop preparing response audio"
        case .playing: "Pause response audio"
        case .paused: "Resume response audio"
        case .unavailable, .checking, .idle: action.title
        }
    }

    private var accessibilityHint: String {
        isActive ? "Playback stays at the current position." : "Uses the latest completed response."
    }

    private var accessibilityValue: String {
        if isActive, let progressText { return progressText }
        if isPreparing { return "Preparing" }
        return switch phase {
        case .playing where isActive: "Playing"
        case .paused where isActive: "Paused"
        default: ""
        }
    }
}
