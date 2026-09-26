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
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
            ScrollView {
                Text(text).herdrFont(size: HerdrTheme.TextSize.body).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(HerdrTheme.accent).frame(width: 2) }
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            TextField("Add a comment…", text: $comment, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .herdrFont(size: HerdrTheme.TextSize.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .herdrField(focused: focused)
                .focused($focused)
                .accessibilityIdentifier("chat-quote-comment")
            if let error { Text(error).herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.alert) }
            HStack {
                Text("Adds to your next message. Not sent yet.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.tertiaryText)
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
        .foregroundStyle(HerdrTheme.text).background(HerdrTheme.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}
