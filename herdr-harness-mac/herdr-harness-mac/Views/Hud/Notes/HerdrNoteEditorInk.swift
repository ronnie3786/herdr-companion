import AppKit
import SwiftUI

/// Attributed TextEditor uses AppKit's insertion color, independently of its
/// SwiftUI foreground style. Scope the native correction to this editor only.
struct HerdrNoteEditorInk: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> InkView { InkView() }
    func updateNSView(_ view: InkView, context: Context) {
        view.ink = NSColor(color)
        view.needsLayout = true
    }

    final class InkView: NSView {
        var ink = NSColor.textColor
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            guard let root = window?.contentView else { return }
            let area = convert(bounds, to: nil)
            func apply(to view: NSView) {
                if let text = view as? NSTextView,
                   area.intersects(text.convert(text.visibleRect, to: nil)) {
                    text.insertionPointColor = ink
                    text.selectedTextAttributes = [.backgroundColor: ink.withAlphaComponent(0.18)]
                }
                for child in view.subviews { apply(to: child) }
            }
            apply(to: root)
        }
    }
}
