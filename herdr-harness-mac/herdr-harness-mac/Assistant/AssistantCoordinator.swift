import AppKit
import CryptoKit
import SwiftUI

/// Windows are presentation only. Closing one never cancels its question.
@MainActor
final class AssistantCoordinator {
    private var sessions: [String: AssistantSession] = [:]
    private var windows: [String: NSWindow] = [:]
    private var popovers: [String: NSPopover] = [:]

    func present(
        title: String,
        machineID: String,
        paneID: String?,
        rootPath: String?,
        context: AssistantContext,
        transport: AssistantTransport,
        profile: String = "contextual-question-v1",
        reviewId: String? = nil,
        anchor: (view: NSView, rect: CGRect)? = nil
    ) -> AssistantSession {
        let identity = [machineID, paneID ?? "", rootPath ?? "", context.source.feature,
                        context.source.instanceId, profile, reviewId ?? ""].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let window = windows[key] {
            updateContext(for: key, context: context)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return sessions[key]!
        }
        if let popover = popovers[key] {
            updateContext(for: key, context: context)
            if let anchor {
                popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
            }
            return sessions[key]!
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herdr/Assistant", isDirectory: true)
        let session = AssistantSession(title: title, machineID: machineID, paneID: paneID, rootPath: rootPath,
                                       context: context, transport: transport,
                                       persistence: AssistantPersistence(url: directory.appendingPathComponent(key + ".json")),
                                       profile: profile, scopeReviewId: reviewId)
        sessions[key] = session
        if let anchor {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.contentSize = NSSize(width: 560, height: 650)
            popover.contentViewController = NSHostingController(rootView: AssistantConversationView(
                session: session,
                openInWindow: { [weak self] in
                    self?.popovers[key]?.close()
                    self?.popovers[key] = nil
                    self?.showWindow(key: key, title: title, session: session)
                }
            ))
            popovers[key] = popover
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
            return session
        }
        showWindow(key: key, title: title, session: session)
        return session
    }

    private func updateContext(for key: String, context: AssistantContext) {
        guard let session = sessions[key] else { return }
        session.currentContext = context
        if session.turns.isEmpty, session.canSend {
            session.context = context
        }
    }

    private func showWindow(key: String, title: String, session: AssistantSession) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Ask Herdr · " + title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AssistantConversationView(session: session))
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
