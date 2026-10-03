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
    var beginVoice: (() -> Void)?
    /// A transient hint for dictation and errors, shown whenever set.
    var composerHint: String?
    /// Guidance shown only while the field is focused.
    var focusedHint: String?
    @FocusState private var focused: Bool
    private var recording: Bool { voice?.phase == .recording || voice?.phase == .locked }
    private var voiceIsBusy: Bool { voice.map { $0.phase != .idle } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                editor
                HStack(spacing: 8) {
                    if openDocuments != nil || attachmentActions != nil {
                        attachmentMenu
                    }
                    if let voice, let beginVoice {
                        FirstMateMicrophoneButton(voice: voice, canControl: canControl && !isSending) {
                            focused = false
                            beginVoice()
                        }
                    }
                    Spacer(minLength: 0)
                    sendButton
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
            .herdrControlGlass(in: .rect(cornerRadius: 24), interactive: false)
            .overlay {
                if recording || focused {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(recording ? HerdrTheme.alert.opacity(0.7) : HerdrTheme.accent.opacity(0.65))
                        .allowsHitTesting(false)
                }
            }
            if voiceIsBusy, let voice {
                HStack {
                    Text(recording ? "Tap Stop to add dictation to your draft." : "Transcribing on this conversation's machine…")
                        .herdrFont(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { voice.cancel() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("first-mate-cancel-dictation")
                }.foregroundStyle(HerdrTheme.secondaryText)
            } else if let hint = canControl ? composerHint ?? (focused ? focusedHint : nil) : unavailableHint {
                Text(hint)
                    .herdrFont(.caption).foregroundStyle(canControl ? HerdrTheme.tertiaryText : HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-composer-hint")
            }
            if let report = voice?.diagnosticReport {
                VoiceTranscriptionDiagnosticsView(report: report)
            }
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
        .preferredColorScheme(.dark)
        .onAppear { focused = initiallyFocused }
    }

    @ViewBuilder private var editor: some View {
        if voiceIsBusy, let voice {
            VStack(alignment: .leading, spacing: 2) {
                if recording {
                    HerdrVoiceWaveform(samples: voice.samples, isRecording: true, showsContainer: false)
                }
                Text(recording ? "Listening…" : "Transcribing…")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 8)
        } else {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                .font(HerdrProse.font(.bubble)).lineSpacing(4)
                .lineLimit(1...7).focused($focused).disabled(!canControl)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .accessibilityLabel("Message First Mate").accessibilityIdentifier("first-mate-composer")
                .composerLayoutMeasurement(id: "composer-text-field")
        }
    }

    private var attachmentMenu: some View {
        Menu {
            if let actions = attachmentActions {
                Button("Photos", systemImage: "photo", action: actions.photos).disabled(!canControl || isSending || voiceIsBusy)
                Button("Files", systemImage: "folder", action: actions.files).disabled(!canControl || isSending || voiceIsBusy)
                if let sample = actions.sample {
                    Button("Add sample attachment", systemImage: "doc", action: sample).disabled(!canControl || isSending || voiceIsBusy)
                }
            }
            Button("Paste code", systemImage: "chevron.left.forwardslash.chevron.right") {
                if let actions = attachmentActions { actions.paste() }
                else { _ = ComposerCodeBlockPaste.paste(into: $text) }
            }.disabled(!canControl || voiceIsBusy)
            if let openDocuments { Button("View documents", systemImage: "doc.text", action: openDocuments) }
        } label: {
            Image(systemName: "plus").font(.body.weight(.medium))
                .frame(width: 44, height: 48).contentShape(.rect)
        }
        .accessibilityLabel("Attachments and conversation resources")
        .accessibilityIdentifier("first-mate-composer-plus")
        .composerLayoutMeasurement(id: "composer-plus-control")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                .frame(width: 36, height: 36).foregroundStyle(HerdrTheme.onPrimary)
                .background(HerdrTheme.accent, in: .circle)
                .frame(width: 44, height: 48).contentShape(.rect)
        }
        .disabled(!canControl || isSending || voiceIsBusy || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments))
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(isSending ? "Sending message" : "Send message")
        .accessibilityIdentifier("first-mate-send")
        .composerLayoutMeasurement(id: "composer-send-control")
    }
}
