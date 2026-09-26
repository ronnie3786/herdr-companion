import SwiftUI

/// The Mac window's top-bar update indicator.
///
/// Visible from the moment a check offers a newer release, and it survives
/// **Later** on the safe-area banner, so the update stays one click away without
/// opening the menu bar.
struct HerdrUpdateToolbarItem: View {
    let updates: HerdrUpdateController

    var body: some View {
        if let version = updates.availableVersion {
            Button {
                updates.checkForUpdates()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(version)
                        .lineLimit(1)
                }
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.accent)
                .padding(.horizontal, 6)
                .frame(height: HerdrTheme.ControlHeight.small)
                .background(HerdrTheme.accent.opacity(0.15), in: .rect(cornerRadius: HerdrTheme.Radius.control))
                .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .help("Herdr \(version) is available. Click to review and install it.")
            .accessibilityLabel("Herdr \(version) is available")
            .accessibilityIdentifier("update-toolbar-item")
        }
    }
}
