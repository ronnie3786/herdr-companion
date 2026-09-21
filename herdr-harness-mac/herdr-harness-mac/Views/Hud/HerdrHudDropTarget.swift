import AppKit
import SwiftUI

/// AppKit drop target for the HUD composer.
///
/// SwiftUI's `onDrop`/`dropDestination` only match providers that already conform
/// to a concrete type. A drag out of the system screenshot preview is a *file
/// promise* whose provider exposes neither `public.file-url` nor `public.image`,
/// so those modifiers never even highlight the HUD. AppKit materializes promises
/// through `NSFilePromiseReceiver`, which is why the HUD uses an explicit drop
/// view. It is mounted behind the SwiftUI content so clicks, hovers, and
/// drag-to-move keep belonging to the views above it.
struct HerdrHudDropTarget: NSViewRepresentable {
    var onTargetingChanged: (Bool) -> Void = { _ in }
    var onDrop: (NSPasteboard) -> Bool
    var registeredTypes: [NSPasteboard.PasteboardType] = HerdrAttachmentDropPolicy.registeredTypes
    var accepts: ([NSPasteboard.PasteboardType]) -> Bool = HerdrAttachmentDropPolicy.accepts

    func makeNSView(context: Context) -> HerdrHudDropView {
        let view = HerdrHudDropView(registeredTypes: registeredTypes)
        view.onTargetingChanged = onTargetingChanged
        view.onDrop = onDrop
        view.accepts = accepts
        return view
    }

    func updateNSView(_ view: HerdrHudDropView, context: Context) {
        view.onTargetingChanged = onTargetingChanged
        view.onDrop = onDrop
        view.accepts = accepts
    }
}

@MainActor
final class HerdrHudDropView: NSView {
    var onTargetingChanged: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    var accepts: ([NSPasteboard.PasteboardType]) -> Bool = HerdrAttachmentDropPolicy.accepts

    init(registeredTypes: [NSPasteboard.PasteboardType]) {
        super.init(frame: .zero)
        registerForDraggedTypes(registeredTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HerdrHudDropView is created in code only")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptable(sender) else {
            onTargetingChanged?(false)
            return []
        }
        onTargetingChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isAcceptable(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetingChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetingChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isAcceptable(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetingChanged?(false)
        return onDrop?(sender.draggingPasteboard) ?? false
    }

    private func isAcceptable(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender.draggingPasteboard.types ?? [])
    }
}
