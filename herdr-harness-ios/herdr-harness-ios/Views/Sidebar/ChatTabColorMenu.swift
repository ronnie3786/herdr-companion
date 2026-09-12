import SwiftUI

/// Shared tab-color assignment menu used by the navigator and pane actions.
/// Assignments and labels belong to this device's app sandbox; this menu never
/// sends color metadata to the companion server.
struct ChatTabColorMenu: View {
    let store: ChatTabColorStore
    let tabID: String

    var body: some View {
        Menu("Tab color", systemImage: "paintpalette") {
            Section("Saved only on this iPhone or iPad") {
                ForEach(ChatTabColor.allCases) { color in
                    Button {
                        store.assign(color, to: tabID)
                    } label: {
                        Label {
                            HStack {
                                Text(store.label(for: color))
                                if store.color(for: tabID) == color {
                                    Image(systemName: "checkmark")
                                }
                            }
                        } icon: {
                            Image(systemName: color.symbol)
                                .foregroundStyle(color.swatch)
                        }
                    }
                    .accessibilityLabel(assignmentLabel(for: color))
                    .accessibilityIdentifier("tab-color-\(color.rawValue)")
                }
            }

            Divider()

            Button("Remove color", systemImage: "circle.slash") {
                store.assign(nil, to: tabID)
            }
            .disabled(store.color(for: tabID) == nil)
            .accessibilityIdentifier("tab-color-remove")
        }
        .disabled(rawTabID.isEmpty)
        .accessibilityHint("Applies locally to every chat in this tab, including future panes")
    }

    private var rawTabID: String {
        MachineScopedID.split(tabID)?.rawID ?? tabID
    }

    private func assignmentLabel(for color: ChatTabColor) -> String {
        let selection = store.color(for: tabID) == color ? ", selected" : ""
        return "\(store.label(for: color)), \(color.defaultLabel)\(selection)"
    }
}
