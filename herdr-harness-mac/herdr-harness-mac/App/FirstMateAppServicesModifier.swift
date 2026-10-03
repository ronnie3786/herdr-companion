import AppKit
import SwiftUI

/// Wires First Mate's process-owned services from whichever window appears:
/// starts the fleet driver and the Dock badge, and gives the app delegate the
/// Dock menu's items and its open action (the delegate has no model or
/// `openWindow`). Applied to the main window and the chat window, so either
/// one alone is enough.
struct FirstMateAppServicesModifier: ViewModifier {
    let appDelegate: HerdrMacAppDelegate
    let model: HerdrAppModel
    let shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            shell.startFirstMateServices(model: model)
            appDelegate.firstMateDockBadge = shell.firstMateDockBadge
            let openWindow = openWindow
            appDelegate.firstMateDockMenuItems = { [weak model, weak shell] in
                guard let model, let shell, let badge = shell.firstMateDockBadge else { return [] }
                return badge.menuItems(model: model, shell: shell)
            }
            appDelegate.openFirstMateDockMenuItem = { [weak model, weak shell] id in
                guard let model, let shell else { return }
                FirstMateChatWindowOpening.open(id, model: model, shell: shell, openWindow: openWindow)
            }
            // The First Mate HUD opens sessions the same way as the Dock menu.
            shell.firstMateHud.openConversation = { [weak model, weak shell] id in
                guard let model, let shell else { return }
                FirstMateChatWindowOpening.open(id, model: model, shell: shell, openWindow: openWindow)
            }
            shell.firstMateHud.openLeadInWindow = { [weak shell] in
                guard let shell else { return }
                FirstMateChatWindowOpening.openLead(shell: shell, openWindow: openWindow)
            }
            shell.firstMateHud.modelFavorites = modelFavorites
        }
    }
}

/// Where a First Mate conversation chosen outside a window (the Dock menu)
/// opens.
@MainActor
enum FirstMateChatWindowOpening {
    static func open(
        _ id: FirstMateFleetFeatureID,
        model: HerdrAppModel,
        shell: HerdrShellState,
        openWindow: OpenWindowAction
    ) {
        route(id, model: model, shell: shell, openWindow: { openWindow(id: $0) })
    }

    static func openLead(shell: HerdrShellState, openWindow: OpenWindowAction) {
        shell.firstMateChatOpenLeadRequest &+= 1
        NSApp.activate()
        openWindow(id: HerdrWindowID.firstMateChat)
    }

    /// Injected activation and window opening keep exact route behavior testable.
    static func route(
        _ id: FirstMateFleetFeatureID,
        model: HerdrAppModel,
        shell: HerdrShellState,
        activate: () -> Void = { NSApp.activate() },
        openWindow: (String) -> Void
    ) {
        shell.firstMateChatOpenRequest = id
        activate()
        openWindow(HerdrWindowID.firstMateChat)
    }
}
