import SwiftUI

struct FirstMateComposerView: View {
    @Bindable var store: FirstMateStore
    let featureStatus: String
    let canControl: Bool
    @Environment(\.colorScheme) private var scheme
    @FocusState private var isFocused: Bool
    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var canSend: Bool {
        canControl && !store.isSending && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(featureStatus == "awaiting_direction" ? "What should we do next?" : "Talk to your First Mate…", text: $store.draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.vertical, 11)
                .accessibilityLabel("Message First Mate")
                .accessibilityIdentifier("first-mate-composer")
            Button(action: send) {
                Group {
                    if store.isSending { ProgressView().tint(palette.background) }
                    else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                }
                .frame(width: 44, height: 44)
                .foregroundStyle(palette.background)
                .background(canSend || store.isSending ? palette.accent : palette.secondaryText.opacity(0.45), in: .circle)
            }
            .disabled(!canSend)
            .buttonStyle(.plain)
            .accessibilityLabel(store.isSending ? "Sending message" : "Send message")
            .accessibilityIdentifier("first-mate-send")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(palette.surface, in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(palette.line, lineWidth: 0.5))
    }

    private func send() {
        guard canSend else { return }
        let context = store.operationContext
        let text = store.draft
        isFocused = false
        Task { await store.send(expectedContext: context, expectedText: text) }
    }
}
