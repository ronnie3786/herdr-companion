import SwiftUI

struct FirstMateMessageView: View {
    let message: FirstMateMessage
    @Environment(\.colorScheme) private var scheme
    private var human: Bool { message.role == "user" || message.role == "human" }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: human ? "person.crop.circle" : "sailboat.fill")
                .herdrFont(.title3).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                .frame(width: 30, height: 30)
                .background(FirstMatePalette(scheme: scheme).accent.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(human ? "You" : "First Mate").herdrFont(.caption, weight: .semibold)
                    if message.status == "queued" { Text("Queued").herdrFont(.caption2).foregroundStyle(.secondary) }
                }
                Text(message.text)
                    .herdrFont(.body).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(human ? 12 : 0)
                    .background(human ? FirstMatePalette(scheme: scheme).surface : .clear, in: .rect(cornerRadius: 9))
            }
        }
    }
}
