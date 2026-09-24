import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import herdr_harness_mac

/// A dragging info that needs no live drag session. The AppKit drop target and
/// the window's real destination search both only read the pasteboard, the
/// destination window, and the location, so a synthetic drag can drive the
/// exact production callbacks.
@MainActor
final class HerdrFakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let destinationWindow: NSWindow?
    var draggingLocation: NSPoint

    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint = NSPoint(x: 200, y: 300)) {
        self.pasteboard = pasteboard
        self.destinationWindow = window
        self.draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { destinationWindow }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@MainActor
enum HerdrDropTestSupport {
    struct Mounted {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>

        func tearDown() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    static func mount(_ content: some View, size: CGSize) -> Mounted {
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return Mounted(window: window, hosting: hosting)
    }

    /// The window's own drag-destination search, i.e. the exact view AppKit
    /// would dispatch a real drag to. Falls back to the mounted hierarchy when
    /// the private selector is unavailable. The method encoding is verified as
    /// "object in, object out" before the call, so an OS change cannot turn
    /// this diagnostic helper into a mismatched call.
    static func destinationView(window: NSWindow, info: NSDraggingInfo) -> NSView? {
        let selector = NSSelectorFromString("_findDragTargetFrom:")
        guard window.responds(to: selector),
              let method = class_getInstanceMethod(type(of: window), selector),
              isObjectToObject(method)
        else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let function = unsafeBitCast(window.method(for: selector), to: Function.self)
        return function(window, selector, info) as? NSView
    }

    private static func isObjectToObject(_ method: Method) -> Bool {
        guard method_getNumberOfArguments(method) == 3 else { return false }
        let returnType = method_copyReturnType(method)
        let argumentType = method_copyArgumentType(method, 2)
        defer {
            free(returnType)
            free(argumentType)
        }
        guard let argumentType else { return false }
        return String(cString: returnType) == "@" && String(cString: argumentType) == "@"
    }

    static func findView<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findView(ofType: type, in: subview) { return found }
        }
        return nil
    }

    static func makePasteboard(_ configure: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HerdrHudDropTargetTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        configure(pasteboard)
        return pasteboard
    }

    static func makePNGFileURL() throws -> URL {
        let url = temporaryURL(named: "dropped-photo.png")
        try HerdrDropImageFixtures.makePNG().write(to: url)
        return url
    }

    static func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    static func makeSession() -> HerdrHudSession {
        let suiteName = "HerdrHudDropTargetTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return HerdrHudSession(
            userDefaults: defaults,
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
    }

    static func waitForAttachments(_ session: HerdrHudSession, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.pendingAttachments.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.pendingAttachments.count == count)
    }

    static func settleDrop() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }
}

@Suite("Herdr HUD drop target", .serialized)
@MainActor
struct HerdrHudDropTargetTests {
    @Test("A Finder file drop lands on the AppKit target exactly once")
    func cardFileDropDispatchesOnce() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let controller = HerdrHudController()
        let session = HerdrDropTestSupport.makeSession()
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: model, controller: controller, session: session),
            size: CGSize(width: 420, height: 580)
        )
        defer { mounted.tearDown() }

        let source = try HerdrDropTestSupport.makePNGFileURL()
        defer { try? FileManager.default.removeItem(at: source) }
        let pasteboard = HerdrDropTestSupport.makePasteboard { $0.writeObjects([source as NSURL]) }
        let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: mounted.window)
        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))

        // The window's real search must choose the AppKit target, not a text
        // view or a SwiftUI provider destination that would shadow it.
        let resolved = HerdrDropTestSupport.destinationView(window: mounted.window, info: info)
        if let resolved {
            #expect(resolved === dropView)
        }
        let target = resolved ?? dropView
        #expect(target.draggingEntered(info) == .copy)
        #expect(target.prepareForDragOperation(info))
        #expect(target.performDragOperation(info))

        try await HerdrDropTestSupport.waitForAttachments(session, count: 1)
        try await HerdrDropTestSupport.settleDrop()
        #expect(session.pendingAttachments.count == 1)
        #expect(session.pendingAttachments.first?.filename == source.lastPathComponent)
    }

    @Test("A drop over the prompt editor still becomes an attachment")
    func editorDropDispatchesToDropTarget() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let controller = HerdrHudController()
        let session = HerdrDropTestSupport.makeSession()
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: model, controller: controller, session: session),
            size: CGSize(width: 420, height: 580)
        )
        defer { mounted.tearDown() }

        let textView = try #require(HerdrDropTestSupport.findView(ofType: NSTextView.self, in: mounted.hosting))
        let editorCenter = textView.convert(
            NSPoint(x: textView.bounds.midX, y: textView.bounds.midY),
            to: nil
        )
        let source = try HerdrDropTestSupport.makePNGFileURL()
        defer { try? FileManager.default.removeItem(at: source) }
        let pasteboard = HerdrDropTestSupport.makePasteboard { $0.writeObjects([source as NSURL]) }
        let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: mounted.window, location: editorCenter)

        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))
        let resolved = HerdrDropTestSupport.destinationView(window: mounted.window, info: info)
        if let resolved {
            // The editor's own text view must not shadow the HUD destination.
            #expect(resolved === dropView)
        }
        let target: NSView = resolved ?? dropView
        #expect(target.draggingEntered(info) == .copy)
        #expect(target.performDragOperation(info))

        try await HerdrDropTestSupport.waitForAttachments(session, count: 1)
        #expect(session.pendingAttachments.first?.filename == source.lastPathComponent)
        #expect(session.draft.isEmpty)
    }

    @Test("Every supported pasteboard source imports exactly one attachment")
    func oneImportPerDropSource() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let source = try HerdrDropTestSupport.makePNGFileURL()
        defer { try? FileManager.default.removeItem(at: source) }

        let sources: [(name: String, configure: (NSPasteboard) -> Void)] = [
            ("file-url", { $0.writeObjects([source as NSURL]) }),
            ("png-data", { $0.setData(bytes, forType: .png) }),
            ("tiff-data", { $0.setData(HerdrDropImageFixtures.makeTIFF(), forType: .tiff) }),
            ("browser-url-and-png", {
                $0.setData(Data("https://example.invalid/photo.png".utf8), forType: NSPasteboard.PasteboardType("public.url"))
                $0.setData(bytes, forType: .png)
            }),
        ]

        for source in sources {
            let session = HerdrDropTestSupport.makeSession()
            let mounted = HerdrDropTestSupport.mount(
                HerdrHudCardView(model: HerdrRenderFixtures.demoModel(), controller: HerdrHudController(), session: session),
                size: CGSize(width: 420, height: 580)
            )
            let pasteboard = HerdrDropTestSupport.makePasteboard(source.configure)
            let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: mounted.window)
            let dropView = try #require(
                HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting)
            )
            #expect(dropView.performDragOperation(info), "\(source.name) was not accepted")
            try await HerdrDropTestSupport.waitForAttachments(session, count: 1)
            try await HerdrDropTestSupport.settleDrop()
            #expect(session.pendingAttachments.count == 1, "\(source.name) imported a duplicate")
            mounted.tearDown()
        }
    }

    @Test("A file promise highlights the AppKit target")
    func promisePasteboardTargetsDropView() async throws {
        let session = HerdrDropTestSupport.makeSession()
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: HerdrRenderFixtures.demoModel(), controller: HerdrHudController(), session: session),
            size: CGSize(width: 420, height: 580)
        )
        defer { mounted.tearDown() }

        let pasteboard = HerdrDropTestSupport.makePasteboard {
            $0.setData(Data([0x01, 0x02, 0x03]), forType: NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"))
            $0.setData(
                Data([0x01, 0x02, 0x03]),
                forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
            )
        }
        let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: mounted.window)
        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))
        let resolved = HerdrDropTestSupport.destinationView(window: mounted.window, info: info)
        if let resolved {
            #expect(resolved === dropView)
        }
        let target: NSView = resolved ?? dropView
        #expect(target.draggingEntered(info) == .copy)
        #expect(target.draggingUpdated(info) == .copy)
    }

    @Test("Text drags never target the HUD")
    func textDragIsNotTargeted() async throws {
        let session = HerdrDropTestSupport.makeSession()
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: HerdrRenderFixtures.demoModel(), controller: HerdrHudController(), session: session),
            size: CGSize(width: 420, height: 580)
        )
        defer { mounted.tearDown() }

        let pasteboard = HerdrDropTestSupport.makePasteboard { $0.setString("just text", forType: .string) }
        let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: mounted.window)
        let resolved = HerdrDropTestSupport.destinationView(window: mounted.window, info: info)
        if let resolved {
            #expect(!(resolved is HerdrHudDropView))
        }
        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))
        #expect(dropView.draggingEntered(info) == [])
        #expect(dropView.draggingUpdated(info) == [])
        #expect(!dropView.prepareForDragOperation(info))
        #expect(!dropView.performDragOperation(info))
        #expect(session.pendingAttachments.isEmpty)
    }

    @Test("Targeting state turns on for acceptable drags and resets on exit and drop")
    func targetingStateResets() async throws {
        var events: [Bool] = []
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudDropTarget(
                onTargetingChanged: { events.append($0) },
                onDrop: { _ in false }
            ),
            size: CGSize(width: 300, height: 200)
        )
        defer { mounted.tearDown() }
        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))

        let acceptable = HerdrDropTestSupport.makePasteboard { $0.setData(HerdrDropImageFixtures.makePNG(), forType: .png) }
        let acceptableInfo = HerdrFakeDraggingInfo(pasteboard: acceptable, window: mounted.window)
        #expect(dropView.draggingEntered(acceptableInfo) == .copy)
        dropView.draggingExited(acceptableInfo)
        #expect(dropView.draggingEntered(acceptableInfo) == .copy)
        #expect(!dropView.performDragOperation(acceptableInfo))
        #expect(events == [true, false, true, false])

        let text = HerdrDropTestSupport.makePasteboard { $0.setString("text", forType: .string) }
        let textInfo = HerdrFakeDraggingInfo(pasteboard: text, window: mounted.window)
        #expect(dropView.draggingEntered(textInfo) == [])
        dropView.draggingEnded(textInfo)
        #expect(events == [true, false, true, false, false, false])
    }

    @Test("Dropping on one card never attaches to another card's session")
    func cardsKeepSeparateSessions() async throws {
        let bytes = HerdrDropImageFixtures.makePNG()
        let first = HerdrDropTestSupport.makeSession()
        let second = HerdrDropTestSupport.makeSession()
        let model = HerdrRenderFixtures.demoModel()
        let firstMount = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: model, controller: HerdrHudController(), session: first),
            size: CGSize(width: 420, height: 580)
        )
        let secondMount = HerdrDropTestSupport.mount(
            HerdrHudCardView(model: model, controller: HerdrHudController(), session: second),
            size: CGSize(width: 420, height: 580)
        )
        defer {
            firstMount.tearDown()
            secondMount.tearDown()
        }

        let pasteboard = HerdrDropTestSupport.makePasteboard { $0.setData(bytes, forType: .png) }
        let info = HerdrFakeDraggingInfo(pasteboard: pasteboard, window: firstMount.window)
        let firstDropView = try #require(
            HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: firstMount.hosting)
        )
        #expect(firstDropView.performDragOperation(info))

        try await HerdrDropTestSupport.waitForAttachments(first, count: 1)
        try await HerdrDropTestSupport.settleDrop()
        #expect(first.pendingAttachments.count == 1)
        #expect(second.pendingAttachments.isEmpty)
    }

    @Test("A drop on the collapsed orb stages in the New chat composer")
    func orbDropTargetsNewChatComposer() async throws {
        let harness = makeConfiguredHarness()
        let orbSession = HerdrDropTestSupport.makeSession()
        let mounted = HerdrDropTestSupport.mount(
            HerdrHudOrbView(model: harness.model, controller: harness.controller, session: orbSession)
                .frame(width: 100, height: 100),
            size: CGSize(width: 100, height: 100)
        )
        defer { mounted.tearDown() }

        let pasteboard = HerdrDropTestSupport.makePasteboard {
            $0.setData(HerdrDropImageFixtures.makePNG(), forType: .png)
        }
        let info = HerdrFakeDraggingInfo(
            pasteboard: pasteboard,
            window: mounted.window,
            location: NSPoint(x: 50, y: 50)
        )
        let dropView = try #require(HerdrDropTestSupport.findView(ofType: HerdrHudDropView.self, in: mounted.hosting))
        #expect(dropView.draggingEntered(info) == .copy)
        #expect(dropView.performDragOperation(info))

        let composer = try #require(harness.controller.chats?.composer)
        try await HerdrDropTestSupport.waitForAttachments(composer, count: 1)
        try await HerdrDropTestSupport.settleDrop()
        #expect(composer.pendingAttachments.count == 1)
        #expect(orbSession.pendingAttachments.isEmpty)
        #expect(harness.controller.chats?.selectedChat == nil)
    }

    // MARK: - Helpers

    private struct Harness {
        let model: HerdrAppModel
        let controller: HerdrHudController
    }

    private func makeConfiguredHarness() -> Harness {
        HerdrTestAppIcon.install()
        let suiteName = "HerdrHudDropTargetHarness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let promptSettings = HerdrPromptSettingsStore(defaults: defaults)
        let session = HerdrHudSession(
            userDefaults: defaults,
            agentSettings: agentSettings,
            persistenceURL: HerdrDropTestSupport.temporaryURL(named: "hud-thread.json"),
            promptSettings: promptSettings
        )
        let notes = HerdrHudNotesState(
            userDefaults: defaults,
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: HerdrDropTestSupport.temporaryURL(named: "hud-notes.json"),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        let controller = HerdrHudController(
            userDefaults: defaults,
            screenshotShortcutStateProvider: { .released },
            commandKeyMonitor: HerdrCommandKeyMonitor(
                keyStateQuery: { _, _ in false },
                flagsQuery: { _ in 0 },
                listenEventAccess: { false },
                requestListenEventAccess: { false }
            ),
            frontmostProcessProvider: { nil }
        )
        controller.configure(
            model: model,
            session: session,
            notes: notes,
            fontScale: HerdrFontScaleStore()
        )
        return Harness(model: model, controller: controller)
    }
}
