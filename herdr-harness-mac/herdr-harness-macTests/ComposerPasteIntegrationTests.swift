import AppKit
import SwiftUI
import Testing
import Vision
@testable import herdr_harness_mac

@Suite("Composer paste actions", .serialized)
@MainActor
struct ComposerPasteIntegrationTests {
    @Test("Real composer buttons and shortcuts append without replacing the selection", arguments: ["main-button", "main-shortcut", "hud-button", "hud-shortcut", "main-button-unfocused", "hud-button-unfocused"])
    func pasteActions(route: String) async throws {
        let domain = "herdr-paste-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let session = HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: root.appendingPathComponent("hud.json"),
            hostIdentity: HerdrHudHostIdentity(hostNames: ["hud.example.invalid"], addresses: [])
        )
        session.draft = "Review 👋 this selection"
        let original = session.draft
        @Bindable var editable = session
        let model = HerdrRenderFixtures.demoModel()
        let pane = try HerdrRenderFixtures.piCapablePane()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let isHud = route.hasPrefix("hud")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("  let value = 1\n", forType: .string)
        // Popovers from earlier cases can outlive their windows; only one
        // opened by this case's composer counts.
        let earlierWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let host = NSHostingView(rootView: Group {
            if isHud {
                // Paste code lives in the `+` popover here too.
                HerdrHudComposerView(model: model, controller: HerdrHudController(userDefaults: defaults), session: session, codePasteboard: board)
                    .environment(\.composerAddMenuInitiallyPresented, route.contains("button"))
            } else {
                // Paste code lives in the composer's `+` popover.
                PromptComposerView(model: model, pane: pane, workspace: workspace, draft: $editable.draft,
                                   attachments: .constant([]), focusRequest: 0, modelFavorites: ModelFavoritesStore(userDefaults: defaults), codePasteboard: board)
                    .environment(\.composerAddMenuInitiallyPresented, route.contains("button"))
            }
        }.frame(width: 540))
        let window: NSWindow = isHud
            ? HerdrHudPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        #expect(window.makeFirstResponder(editor))
        window.makeKey()
        try await Task.sleep(for: .milliseconds(50))
        editor.setSelectedRange(NSRange(location: 7, length: 2))
        let other = NSTextView(frame: NSRect(x: 0, y: host.bounds.height + 100, width: 100, height: 30))
        other.string = original
        if route.hasSuffix("unfocused") {
            host.addSubview(other)
            #expect(window.makeFirstResponder(other))
        }
        if route.contains("button") {
            // Both composers show Paste code in the `+` popover's window.
            let (target, targetView) = try await popoverWindow(for: window, excluding: earlierWindows)
            // The popover fades in; wait until its Paste row has drawn.
            var found: NSPoint?
            for _ in 0..<20 where found == nil {
                found = try? pasteButtonLocation(in: targetView, recordsIssue: false)
                if found == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            let location = try found ?? pasteButtonLocation(in: targetView)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.1,
                windowNumber: target.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            if isHud {
                // The HUD panel's popover takes key once it is clicked, and
                // a click on a popover that is not key yet only activates it.
                // Make it key first, then deliver the click through the event
                // queue the way a real one arrives.
                target.makeKey()
                try await Task.sleep(for: .milliseconds(50))
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
                try await Task.sleep(for: .milliseconds(150))
            } else {
                NSApp.postEvent(up, atStart: true)
                target.sendEvent(down)
                if let pendingUp = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                    target.sendEvent(pendingUp)
                }
            }
        } else {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "V", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        let expected = original + "\n```\n  let value = 1\n```"
        #expect(session.draft == expected)
        #expect(editor.string == expected)
        #expect(other.string == original, "An unrelated focused field must never receive this paste")
        #expect(editor.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.draft == original)
        #expect(editor.string == original)
        #expect(editor.tryToPerform(Selector(("redo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.draft == expected)
        #expect(editor.string == expected)
    }

    /// The `+` popover opened by `composerAddMenuInitiallyPresented`.
    private func popoverWindow(for owner: NSWindow, excluding earlier: Set<ObjectIdentifier>) async throws -> (NSWindow, NSView) {
        for _ in 0..<40 {
            if let popover = NSApp.windows.first(where: {
                $0 !== owner && $0.isVisible && !earlier.contains(ObjectIdentifier($0))
                    && String(describing: type(of: $0)).contains("Popover")
            }), let content = popover.contentView {
                content.layoutSubtreeIfNeeded()
                return (popover, content)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The composer's + popover did not open")
        throw CancellationError()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func pasteButtonLocation(in host: NSView, recordsIssue: Bool = true) throws -> NSPoint {
        // Find the rendered CTA rather than assuming font-dependent coordinates.
        // SwiftUI does not expose its AX children in this hosted unit-test process.
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2),
            pixelsHigh: Int(host.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, image: image)
        let match = request.results?.first { $0.topCandidates(1).first?.string.lowercased().contains("paste") == true }
        guard recordsIssue || match != nil else { throw CancellationError() }
        let label = try #require(match)
        let text = try #require(label.topCandidates(1).first)
        let range = try #require(text.string.lowercased().range(of: "paste"))
        let box = try #require(try text.boundingBox(for: range)).boundingBox
        let point = NSPoint(x: box.midX * host.bounds.width, y: (host.isFlipped ? 1 - box.midY : box.midY) * host.bounds.height)
        return host.convert(point, to: nil)
    }
}
