import SwiftUI

/// Compact primary composer actions plus the secondary tools menu.
struct ComposerAuxiliaryBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attach: () -> Void
    let recordVoice: () -> Void
    let searchFiles: () -> Void
    let chooseJira: () -> Void
    let pasteCodeBlock: () -> Void
    let toggleTerminalKeys: () -> Void
    let startLockedVoiceCapture: () -> Void
    let showsTerminalKeys: Bool
    let canPasteCode: Bool
    let canStartVoiceCapture: Bool
    let voicePhase: HerdrQuickVoiceCapture.Phase
    let beginVoiceHold: () -> Void
    let endVoiceHold: () -> Void
    let finishLockedVoiceCapture: () -> Void

    @State private var hapticPulse = HerdrHapticPulse()
    @State private var isLockPulsing = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            primaryControls(showsTitles: true)
            primaryControls(showsTitles: false)
        }
        .herdrHaptic(trigger: hapticPulse)
        .onChange(of: voicePhase) { _, phase in
            isLockPulsing = phase == .locked
        }
        .onAppear {
            isLockPulsing = voicePhase == .locked
        }
    }

    private func primaryControls(showsTitles: Bool) -> some View {
        HStack(spacing: 4) {
            actionButton(
                title: "Attach",
                systemImage: "paperclip",
                showsTitle: showsTitles,
                action: attach
            )
            voiceButton(showsTitle: showsTitles)
            moreMenu(showsTitle: showsTitles)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func actionButton(
        title: LocalizedStringKey,
        systemImage: String,
        showsTitle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            hapticPulse.fire(.selection)
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if showsTitle {
                    Text(title)
                        .lineLimit(1)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.mist)
        .accessibilityLabel(title)
        .accessibilityIdentifier("composer-attach")
        .composerLayoutMeasurement(id: "composer-attach", label: "Attach")
    }

    private func voiceButton(showsTitle: Bool) -> some View {
        HStack(spacing: 5) {
            if voicePhase == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.mist)
            } else {
                Image(systemName: voicePhase == .locked ? "lock.fill" : "mic.fill")
            }
            if showsTitle {
                Text("Voice")
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isRecordingOrLocked ? HerdrTheme.alert : HerdrTheme.mist)
        .padding(.horizontal, 5)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .scaleEffect(voicePhase == .locked && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(voicePhase == .locked && isLockPulsing && !reduceMotion ? 0.86 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .onTapGesture(perform: activateVoice)
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in beginVoiceHold() }
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { _ in endVoiceHold() }
        )
        .allowsHitTesting(voicePhase != .transcribing)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("composer-record-voice")
        .accessibilityLabel("Record a voice note")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activateVoice() }
        .accessibilityHint("Opens the voice recorder. Press and hold to dictate into the prompt.")
        .composerLayoutMeasurement(
            id: "composer-record-voice",
            label: "Record a voice note"
        )
    }

    private func moreMenu(showsTitle: Bool) -> some View {
        Menu {
            Button("Paste code", systemImage: "doc.on.clipboard", action: pasteCodeBlock)
                .disabled(!canPasteCode)
                .accessibilityIdentifier("composer-paste-code")

            Button("Workspace file", systemImage: "at", action: searchFiles)
                .accessibilityIdentifier("composer-workspace-file")

            Button("Jira ticket", systemImage: "ticket", action: chooseJira)
                .accessibilityIdentifier("composer-jira")

            Divider()

            Button(
                showsTerminalKeys ? "Hide terminal keys" : "Show terminal keys",
                systemImage: "keyboard",
                action: toggleTerminalKeys
            )
            .accessibilityIdentifier("composer-terminal-keys-toggle")

            Button("Start voice dictation", systemImage: "mic", action: startLockedVoiceCapture)
                .disabled(!canStartVoiceCapture)
                .accessibilityIdentifier("composer-start-voice-dictation")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "ellipsis")
                if showsTitle {
                    Text("More")
                        .lineLimit(1)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.mist)
        .accessibilityLabel("More prompt tools")
        .accessibilityValue(showsTerminalKeys ? "Terminal keys shown" : "Terminal keys hidden")
        .accessibilityIdentifier("composer-more-tools")
        .composerLayoutMeasurement(id: "composer-more-tools", label: "More prompt tools")
    }

    private func activateVoice() {
        switch voicePhase {
        case .idle:
            hapticPulse.fire(.selection)
            recordVoice()
        case .locked:
            finishLockedVoiceCapture()
        case .recording, .transcribing:
            break
        }
    }

    private var isRecordingOrLocked: Bool {
        voicePhase == .recording || voicePhase == .locked
    }
}
