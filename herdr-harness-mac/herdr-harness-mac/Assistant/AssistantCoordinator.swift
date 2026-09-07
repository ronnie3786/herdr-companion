import AppKit
import CryptoKit
import SwiftUI

/// Windows are presentation only. Closing one never cancels its question.
@MainActor
final class AssistantCoordinator {
    private var sessions: [String: AssistantSession] = [:]
    private var windows: [String: NSWindow] = [:]

    func present(title: String, machineID: String, paneID: String?, rootPath: String?,
                 context: AssistantContext, transport: AssistantTransport) {
        let identity = [machineID, paneID ?? "", rootPath ?? "", context.source.feature, context.source.instanceId].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let window = windows[key] {
            sessions[key]?.currentContext = context
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herdr/Assistant", isDirectory: true)
        let session = AssistantSession(title: title, machineID: machineID, paneID: paneID, rootPath: rootPath,
                                       context: context, transport: transport,
                                       persistence: AssistantPersistence(url: directory.appendingPathComponent(key + ".json")))
        sessions[key] = session
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
