import SwiftUI

struct FirstMateMicrophoneButton: View {
    let voice: FirstMateMobileVoiceController
    let canControl: Bool
    let begin: () -> Void

    private var recording: Bool { voice.phase == .recording || voice.phase == .locked }
    private var label: String {
        switch voice.phase {
        case .idle: "Start voice dictation"
        case .recording, .locked: "Stop voice dictation"
        case .transcribing: "Transcribing voice dictation"
        }
    }

    var body: some View {
        Button {
            if recording { voice.finish() }
            else if canControl { begin() }
        } label: {
            Group {
                if voice.phase == .transcribing {
                    ProgressView()
                } else {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(recording ? HerdrTheme.onPrimary : HerdrTheme.primaryText)
            .background(recording ? HerdrTheme.alert : HerdrTheme.chipFill, in: .circle)
            .frame(width: 44, height: 48).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(voice.phase == .transcribing || (!canControl && !recording))
        .accessibilityLabel(label)
        .accessibilityHint(recording ? "Stops recording and adds the transcript to your draft." : "Tap to start recording. Tap again to stop and review your words.")
        .accessibilityIdentifier("first-mate-microphone")
        .composerLayoutMeasurement(id: "composer-microphone-control")
    }
}
