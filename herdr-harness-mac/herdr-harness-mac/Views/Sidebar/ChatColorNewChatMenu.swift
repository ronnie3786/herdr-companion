import SwiftUI

/// Provides a direct color-group New chat action for one tab and an explicit
/// destination submenu when the color is assigned to multiple tabs.
struct ChatColorNewChatMenu: View {
    let color: ChatTabColor
    let destinations: [ChatTabColorDestination]
    let canCreate: (ChatTabColorDestination) -> Bool
    let create: (ChatTabColorDestination) -> Void

    var body: some View {
        if destinations.isEmpty {
            Button("New chat", systemImage: "plus.bubble") { }
                .disabled(true)
                .accessibilityIdentifier("chat-color-new-\(color.rawValue)")
        } else if destinations.count == 1, let destination = destinations.first {
            Button("New chat", systemImage: "plus.bubble") {
                create(destination)
            }
            .disabled(!canCreate(destination))
            .help("New chat in \(destination.accessibilityTitle)")
            .accessibilityValue("Destination: \(destination.accessibilityTitle)")
            .accessibilityIdentifier("chat-color-new-\(color.rawValue)")
        } else {
            Menu("New chat", systemImage: "plus.bubble") {
                ForEach(destinations) { destination in
                    ChatColorNewChatDestinationButton(
                        color: color,
                        destination: destination,
                        isEnabled: canCreate(destination),
                        action: { create(destination) }
                    )
                }
            }
            .accessibilityIdentifier("chat-color-new-menu-\(color.rawValue)")
        }
    }
}
