import SwiftUI

/// The large, voice-only view of one agent: what it last said, what you asked,
/// a playback control, and one oversized way to reply. Deliberately has no text
/// field anywhere — Car mode expects you to speak.
struct CarAgentDetailView: View {
    let entry: CarModeStore.Entry
    let scale: CGFloat
    let isWide: Bool
    let isRecording: Bool
    let back: () -> Void
    let play: () -> Void
    let respond: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let asked = entry.summary.asked, !asked.isEmpty {
                askedCard(asked)
            }
            answer
            footer
        }
    }

    private var header: some View {
        HStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                    .frame(
                        width: CarModeMetrics.scaled(CarModeMetrics.backSize, by: scale),
                        height: CarModeMetrics.scaled(CarModeMetrics.backSize, by: scale)
                    )
                    .background(HerdrTheme.graphite, in: .rect(cornerRadius: CarModeMetrics.scaled(16, by: scale)))
                    .overlay {
                        RoundedRectangle(cornerRadius: CarModeMetrics.scaled(16, by: scale))
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("car-detail-back")
            .accessibilityLabel("Back to all agents")

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.pane.displayTitle)
                    .font(.system(size: 21 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text("\(entry.session.workspace.label) · \(entry.session.machineName) · \(entry.session.agentName)")
                    .font(.system(size: 12.5 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CarStatusChip(status: entry.pane.agentStatus, scale: scale)
        }
        .padding(.horizontal, CarModeMetrics.pagePadding)
        .padding(.top, CarModeMetrics.scaled(2, by: scale))
        .padding(.bottom, CarModeMetrics.scaled(8, by: scale))
    }

    private func askedCard(_ asked: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("You asked:")
                .font(.system(size: 14.5 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.accent)
            Text(asked)
                .font(.system(size: 14.5 * scale, weight: .regular))
                .foregroundStyle(HerdrTheme.text.opacity(0.9))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarModeMetrics.scaled(12, by: scale))
        .padding(.vertical, CarModeMetrics.scaled(8, by: scale))
        .background(HerdrTheme.accent.opacity(0.1), in: .rect(cornerRadius: CarModeMetrics.scaled(14, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(14, by: scale))
                .strokeBorder(HerdrTheme.accent.opacity(0.28), lineWidth: 1)
        }
        .padding(.horizontal, CarModeMetrics.pagePadding)
        .padding(.bottom, CarModeMetrics.scaled(8, by: scale))
    }

    private var answer: some View {
        // No text selection on purpose: a selectable text view adds editing
        // affordances (and a keyboard-adjacent element) that a driving surface
        // must not have.
        ScrollView {
            Group {
                if let response = entry.summary.response, !response.isEmpty {
                    CarMarkdownView(source: response, scale: scale, isWide: isWide)
                } else {
                    VStack(alignment: .leading, spacing: CarModeMetrics.scaled(10, by: scale)) {
                        Text(entry.summary.headline)
                            .font(.system(size: (isWide ? 20 : 23) * scale, weight: .semibold))
                            .foregroundStyle(entry.summary.isQuestion ? HerdrTheme.alert : HerdrTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Nothing written yet. Ask by voice and the answer appears here.")
                            .font(.system(size: 15 * scale, weight: .regular))
                            .foregroundStyle(HerdrTheme.mist)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, CarModeMetrics.pagePadding)
            .padding(.bottom, CarModeMetrics.scaled(10, by: scale))
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("car-detail-answer")
    }

    private var footer: some View {
        Group {
            if isWide {
                HStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
                    playButton
                    micButton
                }
            } else {
                VStack(spacing: CarModeMetrics.scaled(8, by: scale)) {
                    playButton
                    micButton
                    Text("Voice only — Car mode has no keyboard")
                        .font(.system(size: 12.5 * scale, weight: .semibold))
                        .foregroundStyle(HerdrTheme.mist)
                }
            }
        }
        .padding(.horizontal, CarModeMetrics.pagePadding)
        .padding(.top, CarModeMetrics.scaled(8, by: scale))
        .padding(.bottom, CarModeMetrics.scaled(10, by: scale))
        .background(HerdrTheme.ink)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.6))
                .frame(height: 1)
        }
    }

    private var playButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            CarAudioButton(
                entry: entry,
                action: .tldr,
                scale: scale,
                isWide: isWide,
                activate: play
            )
            if let progressText = entry.audioPlayer.progressText {
                Text(progressText)
                    .font(.system(size: 12.5 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .frame(maxWidth: isWide ? 220 : .infinity)
    }

    private var micButton: some View {
        Button(action: respond) {
            HStack(spacing: CarModeMetrics.scaled(12, by: scale)) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30 * scale, weight: .bold))
                Text(isRecording ? "Done — transcribe" : "Reply by voice")
                    .font(.system(size: 21 * scale, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(HerdrTheme.input)
            .frame(maxWidth: .infinity)
            .frame(height: CarModeMetrics.scaled(CarModeMetrics.micHeight, by: scale))
            .background(isRecording ? HerdrTheme.alert : HerdrTheme.accent, in: .rect(cornerRadius: CarModeMetrics.scaled(24, by: scale)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("car-mic-cta")
        .accessibilityLabel(isRecording ? "Finish recording your reply" : "Reply by voice")
        .accessibilityHint("Car mode replies are spoken, never typed")
        .composerLayoutMeasurement(id: "car-mic", label: "Reply by voice")
    }
}
