import AppKit
import SwiftUI

/// Grows and shrinks the First Mate chat window's trailing edge so the
/// inspector slides out beside chat instead of covering it.
///
/// Opening adds the inspector's width to the right. When that would cross the
/// screen's edge the window first moves left as far as the screen allows, and
/// closing moves it back by the same amount. A full-screen window cannot
/// change size; `resize` then reports false and the caller shows the column
/// inside the current width.
@MainActor
final class FirstMateChatWindowExtender {
    weak var window: NSWindow?
    /// How far the last open moved the window left to stay on screen.
    private var openShift: CGFloat = 0
    /// The frame an in-flight animation is heading to, so a toggle mid-slide
    /// starts from where the window will be rather than where it is now.
    private var pendingFrame: NSRect?
    private var generation = 0

    static let duration: TimeInterval = 0.24

    /// Adds `delta` points to the window's width (removes them when negative)
    /// and calls `completion` once the frame settles. A newer call cancels an
    /// older call's completion. Returns false, without calling `completion`,
    /// when the window cannot be resized.
    @discardableResult
    func resize(by delta: CGFloat, animated: Bool, completion: @escaping @MainActor () -> Void) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen), window.isVisible else { return false }
        let current = pendingFrame ?? window.frame
        let visible = window.screen?.visibleFrame ?? current
        let target: NSRect
        if delta >= 0 {
            (target, openShift) = Self.grownFrame(current, by: delta, within: visible)
        } else {
            target = Self.shrunkFrame(current, by: -delta, restoring: openShift, within: visible)
            openShift = 0
        }
        generation &+= 1
        let token = generation
        pendingFrame = target
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingFrame = nil
            completion()
        }
        guard animated else {
            window.setFrame(target, display: true)
            finish()
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
        return true
    }

    /// `frame` widened by `delta` to the right. If that crosses the visible
    /// frame's trailing edge, the window moves left as far as the leading
    /// edge allows; on a screen too narrow for both, the width is clamped.
    /// Returns the new frame and how far it moved left.
    nonisolated static func grownFrame(_ frame: NSRect, by delta: CGFloat, within visible: NSRect) -> (NSRect, CGFloat) {
        var target = frame
        target.size.width += delta
        let overflow = target.maxX - visible.maxX
        var shift: CGFloat = 0
        if overflow > 0 {
            shift = max(0, min(overflow, frame.minX - visible.minX))
            target.origin.x -= shift
        }
        if target.maxX > visible.maxX, visible.width > 0 {
            target.size.width = max(frame.width, visible.maxX - target.minX)
        }
        return (target, shift)
    }

    /// `frame` narrowed by `delta` from the right, then moved back right by
    /// the shift its opening applied, without crossing the trailing edge.
    nonisolated static func shrunkFrame(_ frame: NSRect, by delta: CGFloat, restoring shift: CGFloat, within visible: NSRect) -> NSRect {
        var target = frame
        target.size.width = max(0, frame.width - delta)
        let room = visible.width > 0 ? max(0, visible.maxX - target.maxX) : shift
        target.origin.x += min(shift, room)
        return target
    }
}

/// Hands the hosting `NSWindow` to a `FirstMateChatWindowExtender`.
struct FirstMateChatWindowReader: NSViewRepresentable {
    let extender: FirstMateChatWindowExtender

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.extender = extender
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.extender = extender
        extender.window = view.window
    }

    final class ReaderView: NSView {
        weak var extender: FirstMateChatWindowExtender?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            extender?.window = window
        }
    }
}
