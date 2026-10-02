import SwiftUI

struct AgentRoleAvatarView: View {
    let avatar: String
    var size: CGFloat = 32
    var selected = false

    private var identity: AgentRoleAvatar { AgentRoleAvatar(rawValue: avatar) ?? .review }

    var body: some View {
        Image(systemName: identity.systemImage)
            .herdrFont(size: size * 0.43, weight: .medium)
            .foregroundStyle(selected ? HerdrTheme.accent : HerdrTheme.primaryText)
            .frame(width: size, height: size)
            .background(HerdrTheme.firstMateAvatarFill, in: Circle())
            .overlay(Circle().strokeBorder(selected ? HerdrTheme.accent.opacity(0.8) : .clear))
            .accessibilityHidden(true)
    }
}
