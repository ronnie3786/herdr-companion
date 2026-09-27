import SwiftUI

struct ComposerPiMaintenanceActions: View {
    let isEnabled: Bool
    let compact: () -> Void
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerPopoverRow(title: "Compact Chat", systemImage: "arrow.down.right.and.arrow.up.left", action: compact)
                .help("Compact this Pi chat's context")
                .accessibilityIdentifier("composer-compact-pi-chat")
            ComposerPopoverRow(title: "Reload Pi extensions", systemImage: "arrow.clockwise", action: reload)
                .help("Reload this Pi session's extensions")
                .accessibilityIdentifier("composer-reload-pi-session")
        }
        .disabled(!isEnabled)
    }
}

/// A row in the composer's `+` and More popovers: 16pt icon, 13pt title,
/// optional 11pt hint, 5% wash on hover, 8pt corners.
struct ComposerPopoverRow: View {
    let title: String
    let systemImage: String
    var hint: String?
    var accessibilityLabel: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: hint == nil ? .center : .top, spacing: 10) {
                Image(systemName: systemImage)
                    .herdrFont(size: 15)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .frame(width: 18)
                    .padding(.top, hint == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .herdrFont(size: HerdrTheme.TextSize.body)
                        .foregroundStyle(isHovering && isEnabled ? HerdrTheme.primaryText : HerdrTheme.secondaryText)
                    if let hint {
                        Text(hint)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: HerdrTheme.ControlHeight.row, alignment: .leading)
            .background(isHovering && isEnabled ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.composer))
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
