import SwiftUI

extension EnvironmentValues {
    @Entry var saveChatQuote: (@MainActor (ChatQuote) async throws -> Void)? = nil
    @Entry var chatQuoteSource: String = "Chat"
}

struct ChatQuoteEditor: View {
    let text: String
    let source: String
    let save: @MainActor (ChatQuote) async throws -> Void
    let dismiss: () -> Void
    @State private var comment = ""
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quote & comment", systemImage: "quote.bubble")
                .herdrFont(.headline)
            ScrollView {
                Text(text).herdrFont(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(HerdrTheme.accent).frame(width: 2) }
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            TextField("Add a comment…", text: $comment, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .padding(10)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: 8))
                .focused($focused)
                .accessibilityIdentifier("chat-quote-comment")
            if let error { Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.alert) }
            HStack {
                Text("Adds to your next message. Not sent yet.")
                    .herdrFont(.caption2).foregroundStyle(HerdrTheme.muted)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(isSaving ? "Saving…" : "Save") {
                    isSaving = true
                    Task { @MainActor in
                        do {
                            try await save(ChatQuote(text: text, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), source: source))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            isSaving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat-quote-save")
            }
        }
        .padding(16).frame(width: 400)
        .foregroundStyle(HerdrTheme.text).background(HerdrTheme.graphite)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}
