import SwiftUI

struct AgentRoleSkillIssueRow: View {
    let issue: AgentRoleSkillIssue
    let grantAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Label(issue.title, systemImage: issue.needsAccess ? "folder.badge.questionmark" : "exclamationmark.triangle")
                    .herdrFont(.callout, weight: .semibold)
                    .foregroundStyle(HerdrTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if issue.needsAccess {
                    Button("Grant access…", action: grantAccess)
                        .fixedSize()
                }
            }
            Text(issue.message)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(issue.path)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(HerdrTheme.warning.opacity(0.055), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.warning.opacity(0.18)))
    }
}
