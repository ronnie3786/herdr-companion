import SwiftUI

/// Selected skills this Mac doesn't have but the execution computer keeps a
/// saved copy of, such as skills that came with imported roles.
struct AgentRoleSavedCopies: View {
    let store: AgentRolesStore

    var body: some View {
        let machine = store.selectedMachine?.name ?? "the execution computer"
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved copies on \(machine)", systemImage: "externaldrive.badge.checkmark")
                .herdrFont(.callout, weight: .semibold)
            Text("Copied to \(machine). They can't be refreshed from this Mac.")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.savedCopyIDs, id: \.self) { id in
                let name = store.missingSkillName(id)
                HStack(spacing: 8) {
                    Text(verbatim: name)
                        .herdrFont(.caption, weight: .medium)
                        .lineLimit(2)
                        .help(id)
                    Spacer(minLength: 0)
                    Button("Remove", systemImage: "minus.circle") { store.toggleSkill(id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(name)")
                        .disabled(!store.canChangeSkills)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.outline))
        .padding(.bottom, 12)
        .accessibilityIdentifier("agent-role-saved-copies")
    }
}
