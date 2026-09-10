import AppKit
import SwiftUI

/// AppKit help can be suppressed when a nonactivating HUD belongs to an
/// inactive app. An active-always tracking area preserves the normal delay
/// without activating the app or moving focus out of the note editor.
struct HerdrDelayedTooltip: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TooltipView { TooltipView() }
    func updateNSView(_ view: TooltipView, context: Context) { view.title = title }
    static func dismantleNSView(_ view: TooltipView, coordinator: ()) { view.hide() }

    final class TooltipView: NSView {
        var title = ""
        private var area: NSTrackingArea?
        private var pending: Task<Void, Never>?
        private var panel: NSPanel?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
        }
        override func mouseEntered(with event: NSEvent) {
            hide()
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.show()
            }
        }
        override func mouseExited(with event: NSEvent) { hide() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hide() } }
        func hide() {
            pending?.cancel()
            pending = nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil
        }
        private func show() {
            guard let window, !isHiddenOrHasHiddenAncestor else { return }
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .labelColor
            label.sizeToFit()
            let size = NSSize(width: label.frame.width + 16, height: label.frame.height + 10)
            let tip = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            tip.appearance = NSAppearance(named: .aqua)
            tip.backgroundColor = .windowBackgroundColor
            tip.hasShadow = true
            tip.ignoresMouseEvents = true
            tip.isReleasedWhenClosed = false
            tip.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            label.frame.origin = NSPoint(x: 8, y: 5)
            tip.contentView?.addSubview(label)
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? anchor
            let x = min(max(screen.minX, anchor.midX - size.width / 2), screen.maxX - size.width)
            tip.setFrameOrigin(NSPoint(x: x, y: max(screen.minY, anchor.minY - size.height - 6)))
            window.addChildWindow(tip, ordered: .above)
            tip.orderFrontRegardless()
            panel = tip
        }
    }
}

extension View {
    func herdrDelayedTooltip(_ title: String) -> some View {
        background(HerdrDelayedTooltip(title: title)).accessibilityHint(title)
    }
}
