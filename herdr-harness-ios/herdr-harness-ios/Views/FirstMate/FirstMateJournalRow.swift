import SwiftUI

struct FirstMateJournalRow: View {
    let event: FirstMateEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.type.contains("handoff") ? "arrow.turn.down.right" : "clock")
                .font(.system(size: 13))
                .foregroundStyle(HerdrTheme.iconTint)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary).herdrFont(.subheadline).foregroundStyle(HerdrTheme.proseText).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = ISO8601DateFormatter().date(from: event.createdAt) {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .herdrFont(.caption2).foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
