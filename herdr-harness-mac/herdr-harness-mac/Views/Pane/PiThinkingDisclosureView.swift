import SwiftUI

struct PiThinkingDisclosureView: View {
    let block: PiThinkingBlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        PiDisclosureCard(isExpanded: $isExpanded, chevronColor: HerdrTheme.iconTint) {
            markdownContent()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if block.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(HerdrTheme.iconTint)
                            .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                    } else {
                        Image(systemName: "brain.head.profile")
                            .herdrFont(size: HerdrTheme.TextSize.reading)
                            .foregroundStyle(HerdrTheme.iconTint)
                            .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

                Text(block.isStreaming ? "Thinking" : "Thought process")
                    .herdrFont(size: HerdrTheme.TextSize.reading)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .contentTransition(.opacity)

                Spacer(minLength: 8)

                if block.isStreaming, let startedAt = block.startedAt {
                    Text(startedAt, style: .relative)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .transition(.opacity)
                }
            }
        }
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: block.isStreaming)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .onChange(of: block.isStreaming) { wasStreaming, isStreaming in
            guard wasStreaming, !isStreaming else { return }
            PiMarkdownInlineCache.shared.evictStreaming(id: block.id)
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-thinking-\(block.id)")
    }

    private func markdownContent() -> some View {
        let text = visibleText
        let isLiveBlockText = block.isStreaming && !block.isRedacted && !block.text.isEmpty
        if isLiveBlockText {
            PiMarkdownInlineCache.shared.markStreamingEntry(id: block.id, length: text.utf8.count)
        }
        return PiMarkdownText(
            text,
            font: .system(size: HerdrTheme.TextSize.body * fontScale.rawValue),
            id: isLiveBlockText ? block.id : nil,
            cacheKeyLength: isLiveBlockText ? text.utf8.count : nil
        )
        .lineSpacing(HerdrProse.lineSpacing(size: HerdrTheme.TextSize.body, lineHeight: 20, scale: fontScale))
        .environment(\.chatProsePalette, .reasoning)
        .padding(.top, 4)
        .padding(.leading, 22)
    }

    private var visibleText: String {
        if block.isRedacted { return "Reasoning details are unavailable for this response." }
        if block.text.isEmpty { return block.isStreaming ? "Pi is working through the request…" : "No reasoning text was provided." }
        return block.text
    }
}
