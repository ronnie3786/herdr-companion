import SwiftUI

struct FirstMateMessageComposer: View {
    @Binding var text: String
    let placeholder: String
    let canControl: Bool
    let isSending: Bool
    let send: () -> Void
    var openDocuments: (() -> Void)? = nil
    var initiallyFocused = false
    var unavailableHint = "Reconnect to send. Your draft stays here."
    var attachmentActions: FirstMateComposerAttachmentActions?
    var hasAttachments = false
    var voice: FirstMateMobileVoiceController?
    var beginVoice: ((Bool) -> Void)?
    var composerHint: String?
    @FocusState private var focused: Bool
    private var recording: Bool { voice?.phase == .recording || voice?.phase == .locked }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                if openDocuments != nil || attachmentActions != nil {
                    Menu {
                        if let actions = attachmentActions {
                            Button("Photos", systemImage: "photo", action: actions.photos).disabled(!canControl || isSending || recording)
                            Button("Files", systemImage: "folder", action: actions.files).disabled(!canControl || isSending || recording)
                            if let sample = actions.sample { Button("Add sample attachment", systemImage: "doc", action: sample).disabled(!canControl || isSending || recording) }
                        }
                        Button("Paste code", systemImage: "chevron.left.forwardslash.chevron.right") {
                            if let actions = attachmentActions { actions.paste() }
                            else { _ = ComposerCodeBlockPaste.paste(into: $text) }
                        }.disabled(!canControl || recording)
                        if let openDocuments { Button("View documents", systemImage: "doc.text", action: openDocuments) }
                    } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).background(HerdrTheme.codeFill, in: .circle)
                            .frame(width: 44, height: 48).contentShape(.rect)
                    }
                    .accessibilityLabel("Attachments and conversation resources")
                    .accessibilityIdentifier("first-mate-composer-plus")
                    .composerLayoutMeasurement(id: "composer-plus-control")
                }
                HStack(alignment: .bottom, spacing: 4) {
                    if let voice, recording || voice.phase == .transcribing {
                        VStack(alignment: .leading, spacing: 2) {
                            if recording { HerdrVoiceWaveform(samples: voice.samples, isRecording: true, showsContainer: false).frame(height: 32) }
                            Text(voice.phase == .transcribing ? "Transcribing…" : voice.phase == .locked ? "Recording locked" : "Listening…")
                                .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                        }.padding(.leading, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                            .font(HerdrProse.font(.bubble)).lineSpacing(4)
                            .lineLimit(1...7).focused($focused).disabled(!canControl)
                            .padding(.leading, 14).padding(.vertical, 12)
                            .accessibilityLabel("Message First Mate").accessibilityIdentifier("first-mate-composer")
                            .composerLayoutMeasurement(id: "composer-text-field")
                    }
                    if let voice, let beginVoice, (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments) || voice.phase != .idle {
                        FirstMateMicrophoneButton(voice: voice, canControl: canControl && !isSending, begin: beginVoice)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                                .frame(width: 36, height: 36).foregroundStyle(HerdrTheme.onPrimary)
                                .background(HerdrTheme.accent, in: .circle)
                                .frame(width: 44, height: 48).contentShape(.rect)
                        }
                        .disabled(!canControl || isSending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments))
                        .buttonStyle(.plain).padding(.trailing, 2)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel(isSending ? "Sending message" : "Send message")
                        .accessibilityIdentifier("first-mate-send")
                        .composerLayoutMeasurement(id: "composer-send-control")
                    }
                }
                .background(HerdrTheme.codeFill, in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(recording ? HerdrTheme.alert.opacity(0.7) : focused ? HerdrTheme.accent.opacity(0.65) : HerdrTheme.subtleSeparator))
            }
            if let voice, recording || voice.phase == .transcribing {
                HStack {
                    Text(voice.phase == .locked ? "Tap Stop and send when ready." : voice.phase == .transcribing ? "Transcribing on this conversation's machine…" : "Listening. Let go to send. Slide away to cancel.")
                        .herdrFont(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { voice.cancel() }.frame(minWidth: 44, minHeight: 44)
                }.foregroundStyle(HerdrTheme.secondaryText)
            } else {
                Text(canControl ? composerHint ?? "Return adds a new line · ⌘ Return sends" : unavailableHint)
                    .herdrFont(.caption).foregroundStyle(canControl ? HerdrTheme.tertiaryText : HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, openDocuments == nil && attachmentActions == nil ? 0 : 52)
                    .accessibilityIdentifier("first-mate-composer-hint")
            }
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
        .preferredColorScheme(.dark)
        .onAppear { focused = initiallyFocused }
    }
}

private struct FirstMateMicrophoneButton: View {
    let voice: FirstMateMobileVoiceController
    let canControl: Bool
    let begin: (Bool) -> Void
    @State private var hold: Task<Void, Never>?
    @State private var touching = false
    @State private var started = false
    @State private var slidAway = false

    var body: some View {
        Group {
            if voice.phase == .locked {
                Button { voice.finish(explicitSend: true) } label: { icon("stop.fill") }
                    .accessibilityLabel("Stop and send voice message")
            } else if voice.phase == .transcribing {
                ProgressView().frame(width: 44, height: 48).accessibilityLabel("Transcribing voice message")
            } else {
                icon("mic.fill").contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard canControl else { return }
                            if !touching {
                                touching = true; slidAway = false; started = false
                                hold = Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    guard !Task.isCancelled, touching, !slidAway, canControl else { return }
                                    started = true; begin(false)
                                }
                            }
                            if abs(value.translation.width) > 55 || abs(value.translation.height) > 70 {
                                slidAway = true; hold?.cancel(); voice.cancel()
                            }
                        }
                        .onEnded { _ in
                            hold?.cancel(); hold = nil; touching = false
                            if started && !slidAway && voice.phase == .recording { voice.finish(explicitSend: true) }
                            else if !started && !slidAway { voice.quickTap() }
                        })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(voice.phase == .recording ? "Send voice message" : "Hold to talk")
                    .accessibilityHint("Activate to record. Activate again to stop and send.")
                    .accessibilityAction {
                        guard canControl else { return }
                        if voice.phase == .idle { begin(true) } else { voice.finish(explicitSend: true) }
                    }
            }
        }
        .buttonStyle(.plain).disabled(!canControl && voice.phase == .idle)
        .accessibilityIdentifier("first-mate-microphone")
        .composerLayoutMeasurement(id: "composer-microphone-control")
        .onDisappear { hold?.cancel(); hold = nil; touching = false }
    }
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.body.weight(.semibold)).frame(width: 36, height: 36)
            .foregroundStyle(voice.phase == .idle ? HerdrTheme.primaryText : HerdrTheme.onPrimary)
            .background(voice.phase == .idle ? HerdrTheme.chipFill : HerdrTheme.alert, in: .circle)
            .frame(width: 44, height: 48).contentShape(.rect)
    }
}
