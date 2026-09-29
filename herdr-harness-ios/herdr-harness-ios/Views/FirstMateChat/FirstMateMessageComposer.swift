import SwiftUI

struct FirstMateMessageComposer: View {
    @Binding var text: String
    let placeholder: String
    let canControl: Bool
    let isSending: Bool
    let send: () -> Void
    var openDocuments: (() -> Void)? = nil
    var initiallyFocused = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                if let openDocuments {
                    Menu {
                        Button("View documents", systemImage: "doc.text", action: openDocuments)
                    } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).background(HerdrTheme.codeFill, in: .circle)
                            .frame(width: 44, height: 48).contentShape(.rect)
                    }
                    .accessibilityLabel("Conversation resources")
                    .accessibilityIdentifier("first-mate-composer-plus")
                    .composerLayoutMeasurement(id: "composer-plus-control")
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                        .font(HerdrProse.font(.bubble)).lineSpacing(4)
                        .lineLimit(1...7).focused($focused).disabled(!canControl)
                        .padding(.leading, 14).padding(.vertical, 12)
                        .accessibilityLabel("Message First Mate").accessibilityIdentifier("first-mate-composer")
                        .composerLayoutMeasurement(id: "composer-text-field")
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(HerdrTheme.onPrimary)
                            .background(HerdrTheme.accent, in: .circle)
                            .frame(width: 44, height: 48).contentShape(.rect)
                    }
                    .disabled(!canControl || isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.plain).padding(.trailing, 2)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(isSending ? "Sending message" : "Send message")
                    .accessibilityIdentifier("first-mate-send")
                    .composerLayoutMeasurement(id: "composer-send-control")
                }
                .background(HerdrTheme.codeFill, in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(focused ? HerdrTheme.accent.opacity(0.65) : HerdrTheme.subtleSeparator))
            }
            Text(canControl ? "Return adds a new line · ⌘ Return sends" : "Reconnect to send. Your draft stays here.")
                .herdrFont(.caption).foregroundStyle(canControl ? HerdrTheme.tertiaryText : HerdrTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, openDocuments == nil ? 0 : 52)
                .accessibilityIdentifier("first-mate-composer-hint")
        }
        .foregroundStyle(HerdrTheme.primaryText)
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
        .preferredColorScheme(.dark)
        .onAppear { focused = initiallyFocused }
    }
}
