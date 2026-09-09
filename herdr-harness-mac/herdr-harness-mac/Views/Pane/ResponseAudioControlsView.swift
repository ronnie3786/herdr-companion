import SwiftUI

struct ResponseAudioControlsView: View {
    let player: ResponseAudioPlayer
    let showsTitles: Bool
    let activate: (ResponseAudioAction) -> Void

    var body: some View {
        if player.isVisible {
            HStack(spacing: 6) {
                ForEach(ResponseAudioAction.allCases) { action in
                    if player.capabilities.supports(action) {
                        ResponseAudioButton(
                            action: action,
                            phase: player.phase,
                            progressText: player.progressText,
                            showsTitle: showsTitles,
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
    let showsTitle: Bool
    let activate: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 5) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .herdrFont(.caption, weight: .bold)
                }

                if showsTitle {
                    Text(title)
                        .herdrFont(.caption, weight: .medium)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, showsTitle ? 10 : 9)
            .frame(minWidth: PiChatChrome.controlHeight, minHeight: PiChatChrome.controlHeight)
            .background(tint.opacity(isActive ? 0.16 : isHovering ? 0.08 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(tint.opacity(isActive ? 0.45 : 0), lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        }
        .buttonStyle(.plain)
        .disabled(activeAction != nil && activeAction != action)
        .opacity(activeAction != nil && activeAction != action ? 0.38 : 1)
        .onHover { isHovering = $0 }
        .animation(PiChatChrome.hoverAnimation, value: isHovering)
        .help(progressText ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var activeAction: ResponseAudioAction? { phase.activeAction }
    private var isActive: Bool { activeAction == action }
    private var isPreparing: Bool {
        if case let .preparing(activeAction) = phase { return activeAction == action }
        return false
    }

    private var title: String {
        guard isActive else { return action.title }
        return switch phase {
        case .preparing, .playing: "Stop"
        case .paused: "Resume"
        case .unavailable, .checking, .idle: action.title
        }
    }

    private var systemImage: String {
        guard isActive else { return action.systemImage }
        return switch phase {
        case .preparing: "stop.circle.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        case .unavailable, .checking, .idle: action.systemImage
        }
    }

    private var tint: Color {
        if isActive { return phase == .paused(action) ? HerdrTheme.signal : HerdrTheme.working }
        return HerdrTheme.mist
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
        if isPreparing, let progressText { return progressText }
        return isActive ? "Playback stays at the current position." : "Uses the latest completed response."
    }
}
