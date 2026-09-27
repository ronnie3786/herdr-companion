import SwiftUI

struct PanePathButton: View {
    let path: String
    let reportFailure: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: openInFinder) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .herdrFont(size: 13)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
                Text(path)
                    .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isHovering ? HerdrTheme.primaryText : HerdrTheme.tertiaryText)
            .padding(.horizontal, 6)
            .frame(minHeight: HerdrTheme.ControlHeight.small)
            .background(
                isHovering ? HerdrTheme.selectedFill : .clear,
                in: RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
            )
            .herdrHitTarget(minWidth: 0)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovering = $0 }
        .help("Open \(path) in Finder")
        .accessibilityLabel("Open \(path) in Finder")
        .accessibilityHint("Opens this session's working folder")
        .accessibilityIdentifier("pane-path-button")
    }

    private func openInFinder() {
        Task {
            do {
                try await PanePathOpener.open(path: path)
            } catch is CancellationError {
                return
            } catch {
                reportFailure(error.localizedDescription)
            }
        }
    }
}
