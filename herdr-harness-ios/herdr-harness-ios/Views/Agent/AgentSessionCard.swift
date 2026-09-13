import SwiftUI

struct AgentSessionCard: View {
    let session: AgentSession
    let connectionState: ConnectionState
    let isUnread: Bool
    let isStarred: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let titleLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))

        VStack(alignment: .leading, spacing: 6) {
            titleLayout {
                Text(session.pane.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(HerdrTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AgentCardIndicators(
                    isUnread: isUnread,
                    isStarred: isStarred,
                    showsDisclosure: !dynamicTypeSize.isAccessibilitySize
                )
            }

            AgentCardMetadata(session: session, connectionState: connectionState)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
