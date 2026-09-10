import SwiftUI

struct ComposerPiMaintenanceActions: View {
    let isEnabled: Bool
    let compact: () -> Void
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Compact Chat", systemImage: "arrow.down.right.and.arrow.up.left", action: compact)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .help("Compact this Pi chat's context")
                .accessibilityIdentifier("composer-compact-pi-chat")
            Button("Reload Pi extensions", systemImage: "arrow.clockwise", action: reload)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .help("Reload this Pi session's extensions")
                .accessibilityIdentifier("composer-reload-pi-session")
        }
        .buttonStyle(.plain)
        .herdrFont(.caption)
        .foregroundStyle(HerdrTheme.mist)
        .disabled(!isEnabled)
    }
}
