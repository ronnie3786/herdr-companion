import SwiftUI

struct AgentRoleRow: View {
    let role: AgentRole
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: role.locked ? "lock.shield" : "person.fill")
                    .herdrFont(.body)
                    .foregroundStyle(selected ? HerdrTheme.accent : HerdrTheme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(HerdrTheme.elevated, in: Circle())
                    .overlay(Circle().strokeBorder(selected ? HerdrTheme.accent.opacity(0.8) : .clear))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).herdrFont(.callout, weight: .medium).lineLimit(2)
                    Text(role.locked ? "System" : role.skillIds.map { "\($0.count) skills" } ?? "Automatic skills")
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? HerdrTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.herdrPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-role-\(role.id)")
    }
}
