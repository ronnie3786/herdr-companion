import SwiftUI

/// The card beside the HUD, top-aligned in the frame the layout reserved.
struct FirstMateHudCardView: View {
    let controller: FirstMateHudController
    let card: FirstMateHudController.Card

    var body: some View {
        VStack(spacing: 0) {
            switch card {
            case .readout(let id):
                if let item = controller.item(id) {
                    FirstMateHudReadoutCard(controller: controller, item: item)
                        .modifier(FirstMateHudHoverCard(controller: controller))
                }
            case .tucked:
                FirstMateHudTuckedCard(controller: controller, items: controller.tuckedItems)
                    .modifier(FirstMateHudHoverCard(controller: controller))
            case .message(let id):
                if let item = controller.item(id) {
                    FirstMateHudMessageCard(controller: controller, item: item)
                }
            case .editor(let id):
                if let item = controller.item(id) {
                    FirstMateHudEditorCard(controller: controller, item: item)
                }
            case .chat:
                FirstMateHudChatCard(controller: controller)
            case .latestLine:
                FirstMateHudLatestLineCard(controller: controller)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Keeps a hover card open while the pointer is on it.
private struct FirstMateHudHoverCard: ViewModifier {
    let controller: FirstMateHudController

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { controller.holdHoverCard() } else { controller.hover(nil, isInside: false) }
        }
    }
}

/// The emoji, label, and status that head every feature card.
private struct FirstMateHudCardHeader: View {
    let item: FirstMateHudItem
    var title: String? = nil
    var showsMachine = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FirstMateEmojiDisc(emoji: item.emoji, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? item.conversation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(FirstMateChatStatusStyle.label(for: item.hudStatus))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FirstMateChatStatusStyle.color(for: item.hudStatus))
                    if showsMachine {
                        Text(item.conversation.machineName)
                            .font(.system(size: 11))
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The hover readout: the full title, status, the "now" line, six labeled
/// step bars, progress, and Open session plus Read message or Ask First Mate.
struct FirstMateHudReadoutCard: View {
    let controller: FirstMateHudController
    let item: FirstMateHudItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FirstMateHudCardHeader(item: item, showsMachine: controller.showsMachineNames)
            if let now = item.conversation.now.map(FirstMateChatPreview.plainText), !now.isEmpty {
                Text(now)
                    .font(.system(size: 12))
                    .foregroundStyle(HerdrTheme.proseText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            steps
            HStack(spacing: 8) {
                Button("Open session") { controller.openSession(item.id) }
                    .buttonStyle(FirstMateHudButtonStyle(prominent: true))
                if item.showsDot {
                    Button("Read message") { controller.openExplicit(.message(item.id)) }
                        .buttonStyle(FirstMateHudButtonStyle())
                } else {
                    Button("Ask First Mate") {
                        controller.chatDraft = item.label + ": "
                        controller.openExplicit(.chat)
                    }
                    .buttonStyle(FirstMateHudButtonStyle())
                }
            }
        }
        .padding(14)
        .firstMateHudCard(tint: item.needsYou ? FirstMateChatStatusStyle.dotColor(for: item.hudStatus) : nil)
    }

    private var steps: some View {
        let color = FirstMateChatStatusStyle.dotColor(for: item.hudStatus)
        let fills = FirstMateHudProgress.segments(status: item.hudStatus, step: item.conversation.stepIndex, fraction: item.conversation.stepFraction)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(FirstMateChatSteps.names.enumerated()), id: \.offset) { index, name in
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(HerdrTheme.primaryText.opacity(0.10))
                                Capsule().fill(color).frame(width: proxy.size.width * fills[index])
                            }
                        }
                        .frame(height: 4)
                        Text(name)
                            .font(.system(size: 9, weight: index == item.conversation.stepIndex ? .semibold : .regular))
                            .foregroundStyle(index == item.conversation.stepIndex ? HerdrTheme.secondaryText : HerdrTheme.tertiaryText)
                    }
                }
            }
            HStack {
                Text(FirstMateChatStatusStyle.stepText(for: item.conversation) ?? "Step not reported yet")
                Spacer(minLength: 4)
                if let percent = item.percent { Text("\(percent)%").monospacedDigit() }
            }
            .font(.system(size: 11))
            .foregroundStyle(HerdrTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The features behind "+N" or the summary row. Clicking one opens it.
struct FirstMateHudTuckedCard: View {
    let controller: FirstMateHudController
    let items: [FirstMateHudItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(items.count) more")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HerdrTheme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(items) { item in
                Button { controller.openSession(item.id) } label: {
                    HStack(spacing: 8) {
                        FirstMateHudHaloOrb(item: item, size: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.stateWord)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(FirstMateChatStatusStyle.color(for: item.hudStatus))
                                Text(item.percent.map { "\($0)%" } ?? "")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(HerdrTheme.tertiaryText)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            FirstMateHudStepBar(item: item, height: 2, spacing: 2)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FirstMateHudRowButtonStyle())
                .accessibilityLabel(FirstMateHudSpeech.accessibilityLabel(item))
            }
        }
        .padding(10)
        .firstMateHudCard()
    }
}

/// A feature's newest First Mate message, with a reply box whose mic talks
/// to that feature. Opening it marks the message read.
struct FirstMateHudMessageCard: View {
    @Bindable var controller: FirstMateHudController
    let item: FirstMateHudItem
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                FirstMateHudCardHeader(item: item, title: item.label)
                FirstMateHudCloseButton { controller.closeCard(.message(item.id)) }
            }
            ScrollView {
                Text(messageText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HerdrTheme.proseText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 110)
            HStack(spacing: 6) {
                TextField("Reply to \(item.label)", text: $controller.replyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isReplyFocused)
                    .onSubmit { controller.submitReply(to: item.id) }
                FirstMateHudMicButton(controller: controller, target: item.id)
                Button { controller.submitReply(to: item.id) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HerdrTheme.onPrimary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(controller.replyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                                  ? HerdrTheme.primaryDisabled : HerdrTheme.primaryAction))
                }
                .buttonStyle(.plain)
                .disabled(controller.replyDraft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isThinking)
                .accessibilityLabel("Send reply")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).fill(HerdrTheme.fieldFill))
            .overlay { RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).strokeBorder(HerdrTheme.outline, lineWidth: 1) }
            HStack {
                Button("Open session") { controller.openSession(item.id) }
                    .buttonStyle(FirstMateHudButtonStyle())
                Spacer()
                if controller.voicePhase.showsCaption {
                    Text(controller.isListening ? "Listening…" : "Sending…")
                        .font(.system(size: 11))
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
        }
        .padding(14)
        .firstMateHudCard(tint: FirstMateChatStatusStyle.dotColor(for: item.hudStatus))
        .onChange(of: controller.focusRequest, initial: true) { _, _ in isReplyFocused = true }
    }

    private var messageText: String {
        let text = item.conversation.previewIsFromUser ? item.conversation.now ?? "" : item.conversation.previewText
        return text.isEmpty ? FirstMateHudRouting.phrase(item) + "." : text
    }
}

/// Hold to talk to one feature; letting go sends.
private struct FirstMateHudMicButton: View {
    let controller: FirstMateHudController
    let target: FirstMateFleetFeatureID
    @State private var isPressing = false

    var body: some View {
        Image(systemName: controller.isListening ? "waveform" : "mic")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(controller.isListening ? HerdrTheme.alert : HerdrTheme.secondaryText)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing else { return }
                        isPressing = true
                        controller.micPressBegan(target: target)
                    }
                    .onEnded { _ in
                        isPressing = false
                        controller.micPressEnded()
                    }
            )
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
    }
}

/// Rename a feature (24 characters at most) or change its emoji.
struct FirstMateHudEditorCard: View {
    @Bindable var controller: FirstMateHudController
    let item: FirstMateHudItem
    @FocusState private var isLabelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rename \(item.conversation.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                FirstMateHudCloseButton { controller.closeCard(.editor(item.id)) }
            }
            HStack(spacing: 8) {
                TextField("Emoji", text: $controller.editorEmoji)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
                    .frame(width: 40, height: 32)
                    .background(RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).fill(HerdrTheme.fieldFill))
                    .accessibilityLabel("Emoji")
                TextField("Label", text: $controller.editorLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isLabelFocused)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).fill(HerdrTheme.fieldFill))
                    .onChange(of: controller.editorLabel) { _, value in
                        if value.count > FirstMateHudEditing.labelLimit {
                            controller.editorLabel = String(value.prefix(FirstMateHudEditing.labelLimit))
                        }
                    }
                    .onSubmit { controller.saveEditor(for: item.id) }
            }
            HStack(spacing: 2) {
                ForEach(FirstMateDefaultEmoji.palette.prefix(10), id: \.self) { emoji in
                    Button { controller.editorEmoji = emoji } label: {
                        Text(emoji).font(.system(size: 14)).frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(controller.editorEmoji == emoji ? HerdrTheme.selectedFill : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("\(controller.editorLabel.count)/\(FirstMateHudEditing.labelLimit)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(HerdrTheme.tertiaryText)
                Spacer()
                Button("Cancel") { controller.closeCard(.editor(item.id)) }
                    .buttonStyle(FirstMateHudButtonStyle())
                Button("Save") { controller.saveEditor(for: item.id) }
                    .buttonStyle(FirstMateHudButtonStyle(prominent: true))
                    .disabled(controller.editorLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .firstMateHudCard()
        .onChange(of: controller.focusRequest, initial: true) { _, _ in isLabelFocused = true }
    }
}

/// Type to First Mate. Questions about the fleet are answered here; words
/// that name a feature go to it as your message.
struct FirstMateHudChatCard: View {
    @Bindable var controller: FirstMateHudController
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FirstMateFaceOrb(size: 22)
                Text("First Mate")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                FirstMateHudCloseButton { controller.closeCard(.chat) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .herdrHairline(.bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if controller.chatLines.isEmpty {
                            Text("Ask what needs you, or name a feature to send it a message. Hold First Mate to talk.")
                                .font(.system(size: 12))
                                .foregroundStyle(HerdrTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(controller.chatLines) { line in
                            FirstMateHudChatLine(line: line)
                                .id(line.id)
                        }
                        if controller.voicePhase.showsCaption {
                            FirstMateHudVoiceCaption(controller: controller)
                                .id("voice")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.chatLines.count) { _, _ in
                    if let last = controller.chatLines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 6) {
                TextField("Message First Mate", text: $controller.chatDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isComposerFocused)
                    .onSubmit(controller.submitChat)
                Button(action: controller.submitChat) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HerdrTheme.onPrimary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(controller.chatDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                                  ? HerdrTheme.primaryDisabled : HerdrTheme.primaryAction))
                }
                .buttonStyle(.plain)
                .disabled(controller.chatDraft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isThinking)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).fill(HerdrTheme.fieldFill))
            .overlay { RoundedRectangle(cornerRadius: HerdrTheme.Radius.composer).strokeBorder(HerdrTheme.outline, lineWidth: 1) }
            .padding(10)
        }
        .firstMateHudCard(cornerRadius: HerdrTheme.Radius.panel)
        .onChange(of: controller.focusRequest, initial: true) { _, _ in isComposerFocused = true }
    }
}

private struct FirstMateHudChatLine: View {
    let line: FirstMateHudController.ChatLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if line.role == .person { Spacer(minLength: 40) }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(line.role == .person ? HerdrTheme.primaryText : HerdrTheme.proseText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, line.role == .person ? 10 : 0)
                .padding(.vertical, line.role == .person ? 6 : 0)
                .background {
                    if line.role == .person {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HerdrTheme.accent.opacity(0.16))
                    }
                }
            if line.role == .firstMate { Spacer(minLength: 40) }
        }
    }
}

/// First Mate's latest line beside the face, or the caption while talking.
struct FirstMateHudLatestLineCard: View {
    let controller: FirstMateHudController
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FirstMateFaceOrb(size: 14)
                Text("First Mate")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HerdrTheme.tertiaryText)
                Spacer(minLength: 0)
                if isHovering, !controller.voicePhase.showsCaption {
                    FirstMateHudCloseButton(size: 16) { controller.clearLatestLine() }
                }
            }
            if controller.voicePhase.showsCaption {
                FirstMateHudVoiceCaption(controller: controller)
            } else if let line = controller.latestLine {
                Text(line.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .firstMateHudCard()
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let id = controller.latestLine?.featureID { controller.openExplicit(.message(id)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(controller.latestLine?.featureID == nil ? [] : .isButton)
    }
}

/// "Listening…" with the waveform, then the words heard.
private struct FirstMateHudVoiceCaption: View {
    let controller: FirstMateHudController

    var body: some View {
        switch controller.voicePhase {
        case .listening:
            HStack(spacing: 8) {
                HerdrVoiceWaveform(samples: controller.voiceSamples, isRecording: true, showsContainer: false)
                    .frame(height: 18)
                Text("Listening…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HerdrTheme.alert)
            }
        case .transcribing:
            Text("Writing down what you said…")
                .font(.system(size: 12))
                .foregroundStyle(HerdrTheme.secondaryText)
        case .heard(let text):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(3)
        case .idle, .pressing:
            EmptyView()
        }
    }
}

private struct FirstMateHudCloseButton: View {
    var size: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(HerdrTheme.tertiaryText)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// The HUD's small buttons: accent for the main action, ink for the rest.
struct FirstMateHudButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? HerdrTheme.onPrimary : HerdrTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                    .fill(prominent ? (isEnabled ? HerdrTheme.primaryAction : HerdrTheme.primaryDisabled)
                          : configuration.isPressed ? HerdrTheme.selectedFill : HerdrTheme.chipFill)
            )
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
    }
}

/// A list row in a card: a hover fill, nothing else.
private struct FirstMateHudRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                    .fill(configuration.isPressed ? HerdrTheme.selectedFill : isHovering ? HerdrTheme.hoverFill : .clear)
            )
            .onHover { isHovering = $0 }
    }
}
