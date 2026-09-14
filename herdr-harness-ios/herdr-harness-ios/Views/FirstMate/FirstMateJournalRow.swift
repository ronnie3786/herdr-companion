import SwiftUI

struct FirstMateJournalRow: View {
    let event: FirstMateEvent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.type.contains("handoff") ? "arrow.turn.down.right" : "clock")
                .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.summary).font(.subheadline).lineSpacing(3)
                if let date = ISO8601DateFormatter().date(from: event.createdAt) {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
