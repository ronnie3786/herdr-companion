import SwiftUI

/// One agent in Car mode: status, one line of context, and two oversized
/// actions. The header block opens the agent; the actions are separate targets
/// so a reply never requires hitting a small chevron.
struct CarAgentCardView: View {
    let entry: CarModeStore.Entry
    let scale: CGFloat
    let isWide: Bool
    let isVoiceTarget: Bool
    let open: () -> Void
    let play: () -> Void
    let respond: () -> Void

    var body: some View {
        Group {
            if isWide {
                wideRow
            } else {
                portraitCard
            }
        }
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: CarModeMetrics.scaled(18, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(18, by: scale))
                .strokeBorder(edgeColor, lineWidth: entry.summary.isQuestion ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .composerLayoutMeasurement(id: "car-card-\(entry.id)", label: "Agent card")
    }

    private var portraitCard: some View {
        VStack(alignment: .leading, spacing: CarModeMetrics.scaled(4, by: scale)) {
            openButton {
                VStack(alignment: .leading, spacing: CarModeMetrics.scaled(4, by: scale)) {
                    HStack(spacing: CarModeMetrics.scaled(8, by: scale)) {
                        CarStatusChip(status: entry.pane.agentStatus, scale: scale)
                        Spacer(minLength: 6)
                        contextLabel
                    }
                    HStack(alignment: .firstTextBaseline, spacing: CarModeMetrics.scaled(8, by: scale)) {
                        Text(entry.pane.displayTitle)
                            .font(.system(size: 19 * scale, weight: .semibold))
                            .foregroundStyle(HerdrTheme.text)
                            .lineLimit(1)
                        Text(entry.session.agentName)
                            .font(.system(size: 12.5 * scale, weight: .medium))
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14 * scale, weight: .bold))
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    summaryLine
                }
            }
            actions(isWide: false)
        }
        .padding(.horizontal, CarModeMetrics.scaled(12, by: scale))
        .padding(.vertical, CarModeMetrics.scaled(7, by: scale))
    }

    private var wideRow: some View {
        HStack(spacing: CarModeMetrics.scaled(12, by: scale)) {
            openButton {
                VStack(alignment: .leading, spacing: CarModeMetrics.scaled(2, by: scale)) {
                    HStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
                        CarStatusChip(status: entry.pane.agentStatus, scale: scale)
                        Text(entry.pane.displayTitle)
                            .font(.system(size: 16.5 * scale, weight: .semibold))
                            .foregroundStyle(HerdrTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13 * scale, weight: .bold))
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    HStack(spacing: 6) {
                        summaryLine
                        Text("· \(entry.session.workspace.label)")
                            .font(.system(size: 14.5 * scale, weight: .medium))
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
            }
            actions(isWide: true)
        }
        .padding(.horizontal, CarModeMetrics.scaled(10, by: scale))
        .padding(.vertical, CarModeMetrics.scaled(4, by: scale))
    }

    private func openButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button(action: open) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("car-card-\(entry.id)")
        .accessibilityLabel("\(entry.pane.displayTitle). \(entry.pane.agentStatus.title). \(entry.summary.headline). \(entry.session.workspace.label).")
        .accessibilityHint("Opens this agent's answer")
    }

    private func actions(isWide: Bool) -> some View {
        HStack(spacing: CarModeMetrics.scaled(isWide ? 8 : 10, by: scale)) {
            CarAudioButton(
                entry: entry,
                action: .tldr,
                scale: scale,
                isWide: isWide,
                activate: play
            )
            .frame(maxWidth: isWide ? nil : .infinity)
            .frame(width: isWide ? CarModeMetrics.scaled(132, by: scale) : nil)

            CarReplyButton(
                entry: entry,
                scale: scale,
                isWide: isWide,
                isRecording: isVoiceTarget
            ) {
                respond()
            }
            .frame(maxWidth: isWide ? nil : .infinity)
            .frame(width: isWide ? CarModeMetrics.scaled(132, by: scale) : nil)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summaryLine: some View {
        Text(entry.summary.headline)
            .font(.system(size: 16 * scale, weight: entry.summary.isQuestion ? .semibold : .regular))
            .foregroundStyle(entry.summary.isQuestion ? HerdrTheme.alert : HerdrTheme.text.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(entry.summary.headline)
            .composerLayoutMeasurement(id: "car-summary-\(entry.id)", label: entry.summary.headline)
    }

    /// Where this agent lives, or the reason its status is last known.
    @ViewBuilder
    private var contextLabel: some View {
        if entry.connectionState == .live || entry.connectionState == .demo {
            Text("\(entry.session.workspace.label) · \(entry.session.machineName)")
                .font(.system(size: 12.5 * scale, weight: .medium))
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Label(entry.connectionState.title, systemImage: entry.connectionState.symbol)
                .font(.system(size: 12.5 * scale, weight: .semibold))
                .foregroundStyle(entry.connectionState.color)
                .lineLimit(1)
        }
    }

    private var edgeColor: Color {
        if entry.summary.isQuestion { return HerdrTheme.alert.opacity(0.65) }
        if entry.pane.agentStatus == .done { return HerdrTheme.success.opacity(0.4) }
        return HerdrTheme.surface.opacity(0.85)
    }
}
