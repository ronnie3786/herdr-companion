import Carbon.HIToolbox

/// A small, sandbox-safe wrapper around Carbon's process-wide hot-key API.
///
/// Carbon dispatches every registered hot key to one process-wide handler, so
/// instances share a single installed handler and are addressed by their hot-key
/// identifier. The HUD summon hot key keeps identifier 1; other features use
/// their own.
@MainActor
final class HerdrGlobalHotKey {
    nonisolated static let signature: OSType = 0x4848_5544 // "HHUD"
    nonisolated static let summonIdentifier: UInt32 = 1

    private final class Registration {
        weak var hotKey: HerdrGlobalHotKey?

        init(_ hotKey: HerdrGlobalHotKey) {
            self.hotKey = hotKey
        }
    }

    private static var registrations: [UInt32: Registration] = [:]
    private nonisolated(unsafe) static var isHandlerInstalled = false

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let identifier: UInt32
    private let handler: @MainActor () -> Void
    // Carbon dispatches and normally accesses these opaque references on the main thread.
    // `deinit` is a best-effort cleanup path and is nonisolated under Swift 6.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: UInt32 = HerdrGlobalHotKey.summonIdentifier,
        handler: @escaping @MainActor () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.identifier = identifier
        self.handler = handler
    }

    func register() -> Bool {
        if hotKeyRef != nil { return true }

        guard Self.installSharedHandlerIfNeeded() else { return false }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: self.identifier)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        Self.registrations[self.identifier] = Registration(self)
        return true
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        Self.registrations.removeValue(forKey: identifier)
    }

    /// Only a failed install is retried later; a successful one is process-wide.
    private static func installSharedHandlerIfNeeded() -> Bool {
        guard !isHandlerInstalled else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            herdrGlobalHotKeyEventHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard status == noErr else { return false }
        isHandlerInstalled = true
        return true
    }

    fileprivate static func hotKey(for identifier: UInt32) -> HerdrGlobalHotKey? {
        registrations[identifier]?.hotKey
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    fileprivate func invoke() {
        handler()
    }
}

private nonisolated func herdrGlobalHotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == HerdrGlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }

    return MainActor.assumeIsolated {
        guard let hotKey = HerdrGlobalHotKey.hotKey(for: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }
        hotKey.invoke()
        return noErr
    }
}
