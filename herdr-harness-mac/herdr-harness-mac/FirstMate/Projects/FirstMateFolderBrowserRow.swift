import SwiftUI

struct FirstMateFolderBrowserRow: View {
    let entry: FirstMateDirectoryEntry
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isSymlink ? "folder" : "folder.fill")
                .herdrFont(.title3)
                .foregroundStyle(entry.canOpen ? HerdrTheme.accent : HerdrTheme.iconTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .herdrFont(.body)
                    .lineLimit(2)
                if entry.isSymlink, let target = entry.resolvedPath {
                    Text("Link to \(target)")
                        .herdrFont(.callout, monospaced: true)
                        .foregroundStyle(HerdrTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if entry.isSymlink {
                    Label("Symbolic link", systemImage: "link")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
                if !entry.canOpen {
                    Label("Unavailable", systemImage: "lock")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            Button("Open \(entry.name)", systemImage: "chevron.right", action: open)
                .buttonStyle(HerdrIconButtonStyle())
                .disabled(!entry.canOpen)
                .help("Open \(entry.name)")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(entry.isSymlink ? "Symbolic link: \(entry.resolvedPath ?? entry.path)" : entry.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.isSymlink ? "\(entry.name), symbolic link" : entry.name)
        .accessibilityIdentifier("first-mate-folder-row-\(entry.path)")
    }
}
