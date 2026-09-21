import SwiftUI

struct PRReviewAskPopover: View {
    let selection: PRReviewSelection
    let send: (String) -> Void
    let dismiss: () -> Void
    let draftChanged: (Bool) -> Void
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask AI about selection").herdrFont(.headline)
            TextField("Ask a question", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pr-review-ask-field")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["What does this change do?", "Why is this needed?", "What could break?"], id: \.self) { suggestion in
                    Button(suggestion) { question = suggestion }.buttonStyle(.bordered)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Send") { send(question) }.keyboardShortcut(.defaultAction).disabled(question.isEmpty)
            }
        }
        .padding(HerdrTheme.cardPadding)
        .frame(width: 380)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .preferredColorScheme(.dark)
        .onChange(of: question) { _, newValue in
            draftChanged(!newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
