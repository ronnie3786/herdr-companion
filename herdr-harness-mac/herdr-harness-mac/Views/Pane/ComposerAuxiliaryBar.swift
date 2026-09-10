import SwiftUI

/// The utility controls in the composer's tool row.
///
/// The view is intentionally closure-driven so the composer owns presentation
/// and networking state while this control stays reusable and previewable.
///
/// The same controls can appear horizontally or in the More popover. Voice
/// retains click-to-record, hold-to-dictate and hold-to-lock gestures in both.
struct ComposerAuxiliaryBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attach: () -> Void
    let recordVoice: () -> Void
    let searchFiles: () -> Void
    let chooseJira: () -> Void
    let voicePhase: HerdrQuickVoiceCapture.Phase
    let beginVoiceHold: () -> Void
    let endVoiceHold: () -> Void
    let finishLockedVoiceCapture: () -> Void
    var pasteCodeBlock: () -> Void = { }
    /// `nil` lets the bar pick its own fit. The composer's tool row sets it
    /// explicitly, because the fit has to be decided for the whole row — keys
    /// included — not for these four buttons in isolation.
    var showsTitles: Bool?
    var showsAttach = true
    var showsCode = true
    var showsVoice = true
    var showsContextTools = true
    var isVertical = false
    var canPasteCode = true

    @State private var hapticPulse = HerdrHapticPulse()
    @State private var isLockPulsing = false
    @State private var hoveredControl: String?

    /// Hover identity for the voice control, which `auxiliaryButton` does not
    /// build because of its gesture and phase handling.
    private static let voiceControl = "voice"

    var body: some View {
        Group {
            if let showsTitles {
                controls(showsTitles: showsTitles)
            } else {
                ViewThatFits(in: .horizontal) {
                    controls(showsTitles: true)
                    controls(showsTitles: false)
                }
            }
        }
        .herdrHaptic(trigger: hapticPulse)
        .onChange(of: voicePhase) { _, phase in
            isLockPulsing = phase == .locked
            if phase == .transcribing, hoveredControl == Self.voiceControl {
                hoveredControl = nil
            }
        }
        .onAppear {
            isLockPulsing = voicePhase == .locked
        }
    }

    private func controls(showsTitles: Bool) -> some View {
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            if showsAttach {
                auxiliaryButton(
                    identity: "attach",
                    title: "Attach",
                    systemImage: "paperclip",
                    accessibilityLabel: "Attach a file",
                    help: "Attach files to this prompt",
                    showsTitle: showsTitles,
                    action: attach
                )
                .accessibilityIdentifier("composer-attach-file")
            }
            if showsCode {
                auxiliaryButton(
                    identity: "code-block-paste",
                    title: isVertical ? "Paste code block" : "Paste code",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    accessibilityLabel: "Paste Code Block",
                    help: "Append clipboard as a code block (⌘⇧V in the prompt)",
                    showsTitle: showsTitles,
                    action: pasteCodeBlock
                )
                .disabled(!canPasteCode)
                .accessibilityIdentifier("composer-code-block-paste")
            }
            if showsVoice {
                voiceButton(showsTitle: showsTitles)
            }
            if showsContextTools {
                auxiliaryButton(
                    identity: "file",
                    title: "Workspace file",
                    systemImage: "at",
                    accessibilityLabel: "Insert a workspace file path",
                    help: "Search this workspace and insert a file path",
                    showsTitle: showsTitles,
                    action: searchFiles
                )
                auxiliaryButton(
                    identity: "jira",
                    title: "Jira context",
                    systemImage: "ticket",
                    accessibilityLabel: "Insert Jira ticket context",
                    help: "Insert Jira ticket context",
                    showsTitle: showsTitles,
                    action: chooseJira
                )
            }
        }
    }

    private func auxiliaryButton(
        identity: String,
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        help: LocalizedStringKey,
        showsTitle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            hapticPulse.fire(.selection)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .herdrFont(.caption)

                if showsTitle {
                    Text(title)
                        .herdrFont(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hoveredControl == identity ? HerdrTheme.text : HerdrTheme.mist)
            .frame(maxWidth: isVertical ? .infinity : nil, minHeight: HerdrTheme.minHitTarget, alignment: .leading)
            .padding(.horizontal, isVertical ? 10 : 6)
            .background(isVertical || hoveredControl == identity ? HerdrTheme.elevated : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(
                        isVertical ? HerdrTheme.subtleSeparator : .clear,
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredControl = isHovering ? identity : (hoveredControl == identity ? nil : hoveredControl)
        }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func voiceButton(showsTitle: Bool) -> some View {
        HStack(spacing: 6) {
            if voicePhase == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.mist)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: voicePhase == .locked ? "lock.fill" : "mic")
                    .herdrFont(.caption)
            }

            if showsTitle {
                Text("Voice")
                    .herdrFont(.caption)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(voiceForeground)
        .frame(maxWidth: isVertical ? .infinity : nil, minHeight: HerdrTheme.minHitTarget, alignment: .leading)
        .padding(.horizontal, isVertical ? 10 : 6)
        .background(voiceBackground)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(voiceBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .contentShape(.rect)
        .scaleEffect(voicePhase == .locked && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(voicePhase == .locked && isLockPulsing && !reduceMotion ? 0.86 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .onTapGesture { activateVoice() }
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in beginVoiceHold() }
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { _ in endVoiceHold() }
        )
        .allowsHitTesting(voicePhase != .transcribing)
        .focusable(voicePhase != .transcribing)
        .onKeyPress(.return, phases: .down) { _ in
            activateVoice()
            return .handled
        }
        .onKeyPress(.space, phases: .down) { _ in
            activateVoice()
            return .handled
        }
        .onHover { isHovering in
            hoveredControl = isHovering ? Self.voiceControl : (hoveredControl == Self.voiceControl ? nil : hoveredControl)
        }
        .help(voiceHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("composer-record-voice")
        .accessibilityLabel(voicePhase == .locked ? "Finish voice dictation" : "Record a voice note")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activateVoice() }
        .accessibilityHint("Opens the voice recorder. Press and hold to dictate into the prompt.")
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

    private var voiceForeground: Color {
        if isRecordingOrLocked { return HerdrTheme.ink }
        return hoveredControl == Self.voiceControl ? HerdrTheme.text : HerdrTheme.mist
    }

    private var voiceBackground: Color {
        isRecordingOrLocked ? HerdrTheme.alert : (isVertical || hoveredControl == Self.voiceControl ? HerdrTheme.elevated : .clear)
    }

    private var voiceBorder: Color {
        if isRecordingOrLocked { return HerdrTheme.alert }
        return isVertical ? HerdrTheme.subtleSeparator : .clear
    }

    /// The one place the hold-to-dictate gesture is spelled out for a pointer.
    private var voiceHelp: String {
        switch voicePhase {
        case .idle:
            "Click to record a voice note · press and hold to dictate into the prompt"
        case .recording:
            "Dictating, release to transcribe, keep holding to lock"
        case .locked:
            "Recording locked, click to finish and transcribe"
        case .transcribing:
            "Transcribing this dictation"
        }
    }

    private var isRecordingOrLocked: Bool {
        voicePhase == .recording || voicePhase == .locked
    }
}
