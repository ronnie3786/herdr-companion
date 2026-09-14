import SwiftUI

/// A destination row used inside a color shortcut's explicit tab submenu.
struct ChatColorNewChatDestinationButton: View {
    let color: ChatTabColor
    let destination: ChatTabColorDestination
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.displayTitle)
                        .lineLimit(1...2)
                    Text(destination.identityTitle)
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
        }
        .disabled(!isEnabled)
        .help("New chat in \(destination.accessibilityTitle)")
        .accessibilityLabel("New chat in \(destination.accessibilityTitle)")
        .accessibilityIdentifier("chat-color-new-\(color.rawValue)-\(destination.id)")
    }
}
