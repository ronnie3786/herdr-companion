import SwiftUI

struct PiInteractionCardView: View {
    let interaction: PiPendingInteraction
    let isConnected: Bool
    let respond: (PiInteractionResponseBody) async -> Bool
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction.title, systemImage: "person.crop.circle.badge.questionmark")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)

            if let message = interaction.message {
                Text(message)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .lineSpacing(4)
                    .foregroundStyle(HerdrTheme.proseText)
            }

            controls

            Button("Cancel", role: .cancel) {
                submit(.cancelled)
            }
            .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.secondaryText, emphasis: .text))
            .herdrFont(size: HerdrTheme.TextSize.small)
            .disabled(isSubmitting)
        }
        .padding(12)
        // Keeps the attention hue on the ring: this card is waiting on you.
        .herdrCard(outline: HerdrTheme.working.opacity(0.22))
        .herdrHaptic(trigger: hapticPulse)
        .disabled(!isConnected)
        .accessibilityIdentifier("pi-interaction-\(interaction.id)")
    }

    @ViewBuilder
    private var controls: some View {
        switch interaction.kind {
        case .select:
            ForEach(interaction.options, id: \.self) { option in
                Button(option) { submit(.selection(option)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.accent, emphasis: .soft))
                    .disabled(isSubmitting)
            }
        case .confirm:
            HStack {
                Button("No") { submit(.confirmation(false)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.secondaryText, emphasis: .soft))
                Button("Yes") { submit(.confirmation(true)) }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.accent, emphasis: .prominent))
            }
            .disabled(isSubmitting)
        case .input, .editor, .unknown:
            HStack(alignment: .bottom, spacing: 8) {
                TextField(interaction.placeholder ?? "Response", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .herdrField()
                    .onSubmit(submitText)
                Button("Submit", systemImage: "arrow.up", action: submitText)
                    .buttonStyle(HerdrPrimarySquareButtonStyle())
                    .disabled(trimmedText.isEmpty || isSubmitting)
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return in the field submits, matching the Mac idiom. Guarded so an empty
    /// field (or an in-flight response) can't post a blank answer.
    private func submitText() {
        guard !trimmedText.isEmpty, !isSubmitting else { return }
        submit(.text(trimmedText))
    }

    private func submit(_ response: PiInteractionResponseBody) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let succeeded = await respond(response)
            hapticPulse.fire(succeeded ? .completed : .failed)
            isSubmitting = false
        }
    }
}
