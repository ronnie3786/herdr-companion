import SwiftUI

struct AgentSessionCard: View {
    let session: AgentSession
    let connectionState: ConnectionState
    let isUnread: Bool
    let isStarred: Bool
    var sidebar = false
    var isSelected = false
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
        .modifier(AgentSessionSurface(sidebar: sidebar, selected: isSelected))
        .contentShape(.rect)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityElement(children: .combine)
    }
}

private struct AgentSessionSurface: ViewModifier {
    let sidebar: Bool
    let selected: Bool
    func body(content: Content) -> some View {
        if sidebar {
            content.herdrRowBackground(selected: selected, pressed: false)
        } else {
            content.herdrCard(radius: HerdrTheme.Radius.row)
        }
    }
}
