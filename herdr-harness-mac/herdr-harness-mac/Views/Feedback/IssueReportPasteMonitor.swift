import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Makes ⌘V attach a clipboard image even while the title field has focus.
///
/// The sheet's `.onPasteCommand` only sees Edit ▸ Paste when no text view
/// claims it. The title is an `NSTextField`, whose field editor validates
/// Paste against its own readable types: a clipboard holding only a
/// screenshot (PNG/TIFF, no string) is unreadable to it, so the key equivalent
/// is disabled and the command never reaches SwiftUI. This local key monitor
/// runs before that validation and routes such pastes to the composer; any
/// clipboard with text keeps its ordinary text paste, and every text editor —
/// the smart-input box and the description — keeps its own paste entirely.
struct IssueReportPasteMonitor: NSViewRepresentable {
    let composer: IssueReportComposer
    var isTextEditingFocused: Bool
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(composer: composer) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.isTextEditingFocused = isTextEditingFocused
        context.coordinator.isEnabled = isEnabled
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isTextEditingFocused = isTextEditingFocused
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var isTextEditingFocused = false
        var isEnabled = true
        let composer: IssueReportComposer

        init(composer: IssueReportComposer) {
            self.composer = composer
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let view, !view.isHiddenOrHasHiddenAncestor,
                  let window = view.window, event.window === window else { return event }
            let pasteboard = NSPasteboard.general
            guard IssueReportPasteInterceptor.shouldIntercept(
                modifiers: event.modifierFlags,
                key: event.charactersIgnoringModifiers,
                isTextEditingFocused: isTextEditingFocused,
                pasteboardTypes: pasteboard.types ?? []
            ) else { return event }
            return composer.importPasteboardImage(pasteboard) ? nil : event
        }
    }
}

/// The pure decision behind `IssueReportPasteMonitor`, kept separate so it
/// can be tested without a window or a live pasteboard.
enum IssueReportPasteInterceptor {
    static func shouldIntercept(
        modifiers: NSEvent.ModifierFlags,
        key: String?,
        isTextEditingFocused: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard !isTextEditingFocused else { return false }
        guard modifiers.intersection([.command, .shift, .option, .control]) == [.command],
              key?.lowercased() == "v" else { return false }
        return holdsImageWithoutText(pasteboardTypes)
    }

    /// True for a screenshot or copied picture; false as soon as any text
    /// representation is present, so pasting into the title still pastes text.
    static func holdsImageWithoutText(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        var hasImage = false
        for type in types {
            if type == .string || type == .rtf || type == .html { return false }
            guard let utType = UTType(type.rawValue) else { continue }
            if utType.conforms(to: .text) { return false }
            if utType.conforms(to: .image) { hasImage = true }
        }
        return hasImage
    }
}
