import AppKit
import SwiftUI

/// Shared by tab headings and chat menus, including the flat Recents list.
struct ChatTabColorMenu: View {
    let store: ChatTabColorStore
    let tabID: String

    var body: some View {
        Menu("Tab color", systemImage: "paintpalette") {
            ForEach(ChatTabColor.allCases) { color in
                Toggle(isOn: selection(for: color)) {
                    Label {
                        Text(store.label(for: color))
                    } icon: {
                        Image(nsImage: swatch(for: color))
                    }
                }
                .accessibilityIdentifier("tab-color-\(color.rawValue)")
            }
            Divider()
            Button("Remove color", systemImage: "circle.slash") {
                store.assign(nil, to: tabID)
            }
            .disabled(store.color(for: tabID) == nil)
            .accessibilityIdentifier("tab-color-remove")
        }
        .disabled((MachineScopedID.split(tabID)?.rawID ?? tabID).isEmpty)
        .help("Applies to every chat in this tab. Labels and colors are saved on this Mac.")
    }

    private func selection(for color: ChatTabColor) -> Binding<Bool> {
        Binding(
            get: { store.color(for: tabID) == color },
            set: { store.assign($0 ? color : nil, to: tabID) }
        )
    }

    /// SwiftUI tint is not reliably retained when AppKit bridges a context
    /// menu. A non-template swatch preserves the palette beside native checks.
    private func swatch(for color: ChatTabColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(color.swatch).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
