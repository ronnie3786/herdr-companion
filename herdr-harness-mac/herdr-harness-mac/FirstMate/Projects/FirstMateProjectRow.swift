import SwiftUI

struct FirstMateProjectRow: View {
    let choice: FirstMateProjectChoice
    let edit: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: choice.project.isArchived ? "archivebox" : "folder")
                .herdrFont(size: 22).foregroundStyle(HerdrTheme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(choice.project.name).herdrFont(size: HerdrTheme.TextSize.reading, weight: .semibold)
                    if choice.project.isArchived {
                        Text("Archived").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                Text(choice.project.cwd).herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle).help(choice.project.cwd)
                Label("\(choice.host.machineName) · \(choice.host.availabilityLabel)", systemImage: "desktopcomputer")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit", action: edit).help("Edit \(choice.project.name)")
                .accessibilityLabel("Edit \(choice.project.name) on \(choice.host.machineName)")
            if !choice.project.isArchived {
                Button("New session", action: start)
                    .disabled(!choice.host.canManageProjects)
                    .accessibilityLabel("Start session in \(choice.project.name) on \(choice.host.machineName)")
            }
        }
        .padding(.vertical, 20).herdrHairline(.bottom)
        .accessibilityElement(children: .contain)
    }
}
