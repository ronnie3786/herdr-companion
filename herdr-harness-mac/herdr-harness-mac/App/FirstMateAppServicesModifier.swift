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
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            shell.startFirstMateServices(model: model)
            let openWindow = openWindow
            appDelegate.firstMateDockMenuItems = { [weak model, weak shell] in
                guard let model, let shell, let badge = shell.firstMateDockBadge else { return [] }
                return badge.menuItems(model: model, shell: shell)
            }
            appDelegate.openFirstMateDockMenuItem = { [weak model, weak shell] id in
                guard let model, let shell else { return }
                FirstMateChatWindowOpening.open(id, model: model, shell: shell, openWindow: openWindow)
            }
        }
    }
}

/// Where a First Mate conversation chosen outside a window (the Dock menu)
/// opens.
@MainActor
enum FirstMateChatWindowOpening {
    static var isChatWindowEnabled: Bool {
        UserDefaults.standard.object(forKey: FirstMateChatPreferences.windowEnabledKey) as? Bool
            ?? FirstMateChatPreferences.defaultWindowEnabled
    }

    /// With the chat window preview on, the chat window on that conversation;
    /// otherwise the main window's First Mate screen on that feature.
    static func open(
        _ id: FirstMateFleetFeatureID,
        model: HerdrAppModel,
        shell: HerdrShellState,
        openWindow: OpenWindowAction,
        chatWindowEnabled: Bool = isChatWindowEnabled
    ) {
        route(id, model: model, shell: shell, chatWindowEnabled: chatWindowEnabled, openWindow: { openWindow(id: $0) })
    }

    /// ``open(_:model:shell:openWindow:chatWindowEnabled:)`` with the window
    /// opening injected (tests record it).
    static func route(
        _ id: FirstMateFleetFeatureID,
        model: HerdrAppModel,
        shell: HerdrShellState,
        chatWindowEnabled: Bool,
        activate: () -> Void = { NSApp.activate() },
        openWindow: (String) -> Void
    ) {
        if chatWindowEnabled {
            shell.firstMateChatOpenRequest = id
            activate()
            openWindow(HerdrWindowID.firstMateChat)
        } else {
            if model.isDemoMode {
                // The Dock lists the chat window's demo, whose features the
                // main window's demo store does not have.
                shell.show(.firstMate, model: model)
            } else {
                shell.showFirstMate(machineID: id.machineID, featureID: id.featureID, inspector: .overview, model: model)
            }
            activate()
            openWindow(HerdrWindowID.main)
        }
    }
}

/// Closes the chat window when its preview setting turns off, including a
/// window that state restoration brings back while the setting is off.
struct FirstMateChatWindowDismissal: ViewModifier {
    @AppStorage(FirstMateChatPreferences.windowEnabledKey)
    private var isEnabled = FirstMateChatPreferences.defaultWindowEnabled
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: isEnabled, initial: true) { _, enabled in
            if !enabled { dismissWindow(id: HerdrWindowID.firstMateChat) }
        }
    }
}
