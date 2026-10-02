import SwiftUI

struct AgentRoleCatalogNotice: View {
    let issues: [AgentRoleSkillIssue]
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(HerdrTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(issues.count == 1 ? issues[0].title : "\(issues.count) skill folders need attention")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                Text("Available skills are shown below. Review folder access to include the rest.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Review folders", action: review)
                .fixedSize()
        }
        .padding(12)
        .background(HerdrTheme.warning.opacity(0.055), in: .rect(cornerRadius: 9))
        .accessibilityIdentifier("agent-role-local-folder-notice")
    }
}
