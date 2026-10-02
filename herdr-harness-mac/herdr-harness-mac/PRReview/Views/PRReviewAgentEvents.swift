import SwiftUI

struct PRReviewAgentEvents: View {
    let events: [PRReviewEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(events.sorted { $0.sequence > $1.sequence }) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.summary).herdrFont(.callout)
                    Text(event.createdAt.prefix(16)).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pr-review-events")
    }
}
