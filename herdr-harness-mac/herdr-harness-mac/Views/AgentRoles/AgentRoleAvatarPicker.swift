import SwiftUI

struct AgentRoleAvatarPicker: View {
    @Binding var avatar: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Avatar").herdrFont(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 6)], alignment: .leading, spacing: 8) {
                ForEach(AgentRoleAvatar.allCases) { choice in
                    Button {
                        avatar = choice.rawValue
                    } label: {
                        AgentRoleAvatarView(avatar: choice.rawValue, size: 36, selected: avatar == choice.rawValue)
                            .overlay(alignment: .bottomTrailing) {
                                if avatar == choice.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .herdrFont(.caption)
                                        .foregroundStyle(HerdrTheme.accent)
                                        .background(HerdrTheme.ink, in: Circle())
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(3)
                    }
                    .buttonStyle(.herdrPlain)
                    .help(choice.title)
                    .accessibilityLabel("\(choice.title) avatar")
                    .accessibilityAddTraits(avatar == choice.rawValue ? .isSelected : [])
                    .accessibilityIdentifier("agent-role-avatar-\(choice.rawValue)")
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }
}
