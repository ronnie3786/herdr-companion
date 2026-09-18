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
                        .herdrFont(.caption, weight: .semibold)
                    Text(version)
                        .herdrFont(.caption, weight: .semibold)
                        .lineLimit(1)
                }
                .foregroundStyle(HerdrTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(HerdrTheme.accent.opacity(0.12), in: .capsule)
                .overlay {
                    Capsule().strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .herdrHitTarget()
            .help("Herdr \(version) is available. Click to review and install it.")
            .accessibilityLabel("Herdr \(version) is available")
            .accessibilityIdentifier("update-toolbar-item")
        }
    }
}
