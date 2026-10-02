import SwiftUI

struct FirstMateProjectHostNotice: View {
    let host: FirstMateProjectHost?
    var manual = false

    var body: some View {
        if let host {
            if host.isLoading && !host.hasLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(host.machineName)…").herdrFont(size: HerdrTheme.TextSize.small)
                }
            } else if let error = host.error {
                FirstMateProjectNotice(text: error, warning: true)
            } else if !manual && host.hasLoaded && !host.supportsProjects {
                FirstMateProjectNotice(text: "Update the companion on \(host.machineName) to save projects. Manual setup is still available.")
            } else if host.hasLoaded && !host.supportsDirectoryBrowser {
                Text("Enter the full folder path. Update this companion to browse its folders.")
                    .herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
        }
    }
}
