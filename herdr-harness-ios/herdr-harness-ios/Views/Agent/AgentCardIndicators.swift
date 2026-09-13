import SwiftUI

struct AgentCardIndicators: View {
    let isUnread: Bool
    let isStarred: Bool
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isUnread {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityLabel("Unread")
            }
            if isStarred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .accessibilityLabel("Starred")
            }
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)
            }
        }
    }
}
