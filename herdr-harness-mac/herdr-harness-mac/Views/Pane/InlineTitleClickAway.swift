import AppKit
import SwiftUI

/// Text fields retain focus when a user clicks non-focusable chat content.
/// Observe those clicks too, without consuming the destination's mouse event.
struct InlineTitleClickAway: NSViewRepresentable {
    var commit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, view.window != nil else { return event }
            if event.window !== view.window || !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                coordinator.commit()
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.commit = commit
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var commit: () -> Void
        init(commit: @escaping () -> Void) { self.commit = commit }
    }
}
