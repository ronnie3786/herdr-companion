import SwiftUI

struct FirstMateActivityMessageView: View {
    let message: FirstMateMessage
    let isProcessing: Bool
    @State private var expanded = false

    private var title: String {
        if isProcessing { return "Coordinator working on" }
        return ["user", "human"].contains(message.role) ? "Your direction" : "Background update"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: isProcessing ? "arrow.triangle.2.circlepath" : "clock")
                .firstMateActivityFont(.caption, weight: .medium).foregroundStyle(.secondary)
            Text(message.text)
                .firstMateActivityFont(.subheadline)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if message.text.count > 160 || message.text.contains("\n") {
                Button(expanded ? "Show less" : "Show direction") { expanded.toggle() }
                    .buttonStyle(.plain).firstMateActivityFont(.caption)
                    .frame(minHeight: 44)
            }
            if message.textTruncated == true {
                Text("Preview of a longer direction").firstMateActivityFont(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-pending-\(message.id)")
    }
}
