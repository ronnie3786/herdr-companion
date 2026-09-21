import SwiftUI

/// The full-screen voice surface. It covers the grid whenever a reply is being
/// recorded, transcribed, confirmed, or delivered, so there is exactly one
/// obvious thing on screen while the phone is mounted.
struct CarVoiceCaptureView: View {
    let phase: CarModeStore.VoicePhase
    let agentTitle: String
    let workspaceLabel: String
    let disposition: PiPromptDisposition
    let samples: [CGFloat]
    let scale: CGFloat
    let isWide: Bool
    let confirmsTranscripts: Bool
    let finish: () -> Void
    let send: () -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            HerdrTheme.crust.ignoresSafeArea()
            if isWide {
                HStack(spacing: CarModeMetrics.scaled(20, by: scale)) {
                    head.frame(width: CarModeMetrics.scaled(230, by: scale), alignment: .leading)
                    stage
                    actions.frame(width: CarModeMetrics.scaled(300, by: scale))
                }
                .padding(.horizontal, CarModeMetrics.scaled(22, by: scale))
                .padding(.vertical, CarModeMetrics.scaled(16, by: scale))
            } else {
                VStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
                    head
                    stage
                    actions
                }
                .padding(.horizontal, CarModeMetrics.scaled(20, by: scale))
                .padding(.top, CarModeMetrics.scaled(24, by: scale))
                .padding(.bottom, CarModeMetrics.scaled(16, by: scale))
            }
        }
    }

    private var head: some View {
        VStack(alignment: isWide ? .leading : .center, spacing: 3) {
            Text("\(agentTitle) · \(workspaceLabel)")
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.mist)
                .textCase(.uppercase)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 24 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.text)
                .multilineTextAlignment(isWide ? .leading : .center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: isWide ? nil : .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var stage: some View {
        VStack(spacing: CarModeMetrics.scaled(14, by: scale)) {
            switch phase {
            case let .recording(startedAt):
                recordingStage(startedAt: startedAt)
            case .transcribing:
                orb(systemImage: "waveform", tint: HerdrTheme.accent, isPulsing: false)
                ProgressView()
                    .controlSize(.large)
                    .tint(HerdrTheme.accent)
                HerdrVoiceWaveform(samples: samples, isRecording: false, showsContainer: false)
                    .frame(height: CarModeMetrics.scaled(52, by: scale))
                    .opacity(0.55)
                footnote("On device when possible, otherwise your private server.")
            case let .review(text):
                transcriptCard(text)
            case let .sending(text):
                transcriptCard(text)
                ProgressView()
                    .controlSize(.large)
                    .tint(HerdrTheme.accent)
            case .sent:
                orb(systemImage: "checkmark", tint: HerdrTheme.success, isPulsing: false)
                Text(sentDetail)
                    .font(.system(size: 19 * scale, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: CarModeMetrics.scaled(320, by: scale))
            case let .failed(message):
                orb(systemImage: "exclamationmark.triangle.fill", tint: HerdrTheme.alert, isPulsing: false)
                Text(message)
                    .font(.system(size: 16 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.alert)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: CarModeMetrics.scaled(340, by: scale))
                footnote("Car mode never asks you to type.")
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordingStage(startedAt: Date) -> some View {
        VStack(spacing: CarModeMetrics.scaled(12, by: scale)) {
            orb(systemImage: "mic.fill", tint: HerdrTheme.alert, isPulsing: true)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(formattedDuration(from: startedAt, now: context.date))
                    .font(.system(size: 34 * scale, weight: .bold).monospacedDigit())
                    .foregroundStyle(HerdrTheme.text)
            }
            HerdrVoiceWaveform(samples: samples, isRecording: true, showsContainer: false)
                .frame(height: CarModeMetrics.scaled(60, by: scale))
        }
    }

    private func transcriptCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: CarModeMetrics.scaled(8, by: scale)) {
            Text("Transcript")
                .font(.system(size: 12.5 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.mist)
                .textCase(.uppercase)
            ScrollView {
                Text(text)
                    .font(.system(size: 23 * scale, weight: .regular))
                    .foregroundStyle(HerdrTheme.text)
                    .lineSpacing(CarModeMetrics.scaled(3, by: scale))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(CarModeMetrics.scaled(16, by: scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: CarModeMetrics.scaled(20, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(20, by: scale))
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .accessibilityIdentifier("car-voice-transcript")
    }

    private var actions: some View {
        VStack(spacing: CarModeMetrics.scaled(9, by: scale)) {
            switch phase {
            case .recording:
                bigButton(
                    title: "Done — transcribe",
                    systemImage: "stop.fill",
                    tint: HerdrTheme.alert,
                    identifier: "car-voice-finish",
                    action: finish
                )
                secondaryRow {
                    smallButton("Cancel", identifier: "car-voice-cancel", action: cancel)
                    smallButton("Restart", identifier: "car-voice-restart", action: retry)
                }
            case .transcribing:
                smallButton("Cancel", identifier: "car-voice-cancel", action: cancel)
            case let .review(text):
                banner(
                    text: confirmsTranscripts
                        ? "Confirm before sending. \(CarModeSendPolicy.confirmationLabel(for: disposition))."
                        : "Auto-send is on. \(CarModeSendPolicy.confirmationLabel(for: disposition))."
                )
                bigButton(
                    title: "Send to \(workspaceLabel)",
                    systemImage: "paperplane.fill",
                    tint: HerdrTheme.accent,
                    identifier: "car-voice-send",
                    action: send
                )
                .accessibilityHint(text)
                secondaryRow {
                    smallButton("Say it again", systemImage: "arrow.counterclockwise", identifier: "car-voice-retry", action: retry)
                    smallButton("Cancel", identifier: "car-voice-cancel", action: cancel)
                }
            case .sending:
                ProgressView()
                    .controlSize(.large)
                    .tint(HerdrTheme.accent)
                smallButton("Cancel", identifier: "car-voice-cancel", action: cancel)
            case .sent:
                smallButton("Back to agents", identifier: "car-voice-done", action: cancel)
            case .failed:
                bigButton(
                    title: "Record again",
                    systemImage: "mic.fill",
                    tint: HerdrTheme.accent,
                    identifier: "car-voice-retry",
                    action: retry
                )
                smallButton("Cancel", identifier: "car-voice-cancel", action: cancel)
            case .idle:
                EmptyView()
            }
        }
    }

    private func orb(systemImage: String, tint: Color, isPulsing: Bool) -> some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(tint.opacity(0.28))
                    .frame(
                        width: CarModeMetrics.scaled(190, by: scale),
                        height: CarModeMetrics.scaled(190, by: scale)
                    )
            }
            Circle()
                .fill(tint)
                .frame(
                    width: CarModeMetrics.scaled(150, by: scale),
                    height: CarModeMetrics.scaled(150, by: scale)
                )
            Image(systemName: systemImage)
                .font(.system(size: 62 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.input)
        }
        .accessibilityHidden(true)
    }

    private func banner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15 * scale, weight: .bold))
            Text(text)
                .font(.system(size: 14.5 * scale, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(HerdrTheme.working)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CarModeMetrics.scaled(12, by: scale))
        .padding(.vertical, CarModeMetrics.scaled(10, by: scale))
        .background(HerdrTheme.working.opacity(0.12), in: .rect(cornerRadius: CarModeMetrics.scaled(14, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(14, by: scale))
                .strokeBorder(HerdrTheme.working.opacity(0.5), lineWidth: 1)
        }
    }

    private func bigButton(
        title: String,
        systemImage: String,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
                Image(systemName: systemImage)
                    .font(.system(size: 22 * scale, weight: .bold))
                Text(title)
                    .font(.system(size: 20 * scale, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(HerdrTheme.input)
            .frame(maxWidth: .infinity)
            .frame(height: CarModeMetrics.scaled(88, by: scale))
            .background(tint, in: .rect(cornerRadius: CarModeMetrics.scaled(22, by: scale)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .composerLayoutMeasurement(id: identifier, label: title)
    }

    private func smallButton(
        _ title: String,
        systemImage: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CarModeMetrics.scaled(6, by: scale)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15 * scale, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 16 * scale, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(HerdrTheme.text)
            .frame(maxWidth: .infinity)
            .frame(height: CarModeMetrics.scaled(60, by: scale))
            .background(HerdrTheme.graphite, in: .rect(cornerRadius: CarModeMetrics.scaled(16, by: scale)))
            .overlay {
                RoundedRectangle(cornerRadius: CarModeMetrics.scaled(16, by: scale))
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: CarModeMetrics.scaled(9, by: scale)) {
            content()
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13 * scale, weight: .medium))
            .foregroundStyle(HerdrTheme.mist)
            .multilineTextAlignment(.center)
            .frame(maxWidth: CarModeMetrics.scaled(340, by: scale))
    }

    private var title: String {
        switch phase {
        case .recording: "Listening…"
        case .transcribing: "Turning that into text…"
        case .review: "Send this?"
        case .sending: "Sending…"
        case .sent: "Sent"
        case .failed: "That didn't work"
        case .idle: ""
        }
    }

    private var sentDetail: String {
        switch disposition {
        case .steer: "Steering the turn that is running."
        case .followUp: "Queued after the running turn."
        case .prompt: "Delivered as the next message."
        }
    }

    private func formattedDuration(from start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }
}
