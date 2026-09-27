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
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 4))
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
            controlLabel(
                systemImage: systemImage,
                title: title,
                showsTitle: showsTitle,
                isHovered: hoveredControl == identity
            )
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovering in
            hoveredControl = isHovering ? identity : (hoveredControl == identity ? nil : hoveredControl)
        }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    /// MonoCode's ghost icon button (26pt, 50% ink, 10% wash on hover) in the
    /// toolbar, or a 32pt popover row (16pt icon, 13pt title, 5% hover).
    @ViewBuilder
    private func controlLabel(
        systemImage: String,
        title: LocalizedStringKey,
        showsTitle: Bool,
        isHovered: Bool
    ) -> some View {
        if isVertical {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .herdrFont(size: 15)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .frame(width: 18)
                Text(title)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(isHovered ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: HerdrTheme.ControlHeight.row, alignment: .leading)
            .background(isHovered ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
            .contentShape(.rect)
        } else {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .herdrFont(size: HerdrTheme.TextSize.reading)
                if showsTitle {
                    Text(title)
                        .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isHovered ? HerdrTheme.primaryText : HerdrTheme.iconTint)
            .padding(.horizontal, showsTitle ? 6 : 0)
            .frame(minWidth: HerdrTheme.ControlHeight.regular, minHeight: HerdrTheme.ControlHeight.regular)
            .background(isHovered ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
        }
    }

    private func voiceButton(showsTitle: Bool) -> some View {
        Group {
            if isRecordingOrLocked || voicePhase == .transcribing {
                HStack(spacing: 6) {
                    if voicePhase == .transcribing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(HerdrTheme.iconTint)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: voicePhase == .locked ? "lock.fill" : "mic.fill")
                            .herdrFont(size: HerdrTheme.TextSize.reading)
                    }
                    if showsTitle {
                        Text("Voice")
                            .herdrFont(size: isVertical ? HerdrTheme.TextSize.body : HerdrTheme.TextSize.caption, weight: .medium)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(voiceForeground)
                .padding(.horizontal, showsTitle ? 8 : 0)
                .frame(maxWidth: isVertical ? .infinity : nil, minHeight: HerdrTheme.ControlHeight.regular, alignment: isVertical ? .leading : .center)
                .frame(minWidth: HerdrTheme.ControlHeight.regular)
                .background(voiceBackground, in: .rect(cornerRadius: HerdrTheme.Radius.control))
                .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                .contentShape(.rect)
            } else {
                controlLabel(
                    systemImage: "mic",
                    title: "Voice",
                    showsTitle: showsTitle,
                    isHovered: hoveredControl == Self.voiceControl
                )
            }
        }
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
        isRecordingOrLocked ? HerdrTheme.onPrimary : HerdrTheme.iconTint
    }

    private var voiceBackground: Color {
        isRecordingOrLocked ? HerdrTheme.alert : .clear
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
