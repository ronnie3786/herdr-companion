import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Which signal observed a Command-key press. Recorded for the App Shots
/// diagnostics readout so a detection problem can be told apart from a
/// capture problem without a debugger.
enum HerdrCommandKeySignal: String, Equatable, Sendable {
    /// A global `flagsChanged` monitor supplied the per-key state.
    case globalMonitor
    /// The permission-free Quartz per-key state table supplied the press.
    case keyState
    /// The permission-free Quartz modifier device bits supplied the press.
    case flagsState
    /// Nothing has reported a press yet.
    case unavailable

    var title: String {
        switch self {
        case .globalMonitor: "Keyboard access"
        case .keyState: "Key state"
        case .flagsState: "Modifier flags"
        case .unavailable: "Not observed"
        }
    }
}

struct HerdrCommandKeyState: Equatable, Sendable {
    let isLeftCommandPressed: Bool
    let isRightCommandPressed: Bool
    let signal: HerdrCommandKeySignal

    var isChordPressed: Bool {
        isLeftCommandPressed && isRightCommandPressed
    }

    static let released = HerdrCommandKeyState(
        isLeftCommandPressed: false,
        isRightCommandPressed: false,
        signal: .unavailable
    )
}

/// Reads the two Command keys without consuming key events, synthesizing input,
/// or installing an accessibility event tap.
///
/// Two always-available, permission-free signals are polled and unioned, because
/// either one may be unavailable on a given macOS build or process context:
/// `CGEventSource.keyState` for each Command key code, and the device-dependent
/// bits (`NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK`) of the combined-session
/// modifier flags. When Input Monitoring is already granted, a global
/// `flagsChanged` monitor is the authoritative source and the polls act as its
/// cross-check.
///
/// Nothing here observes key characters, other keys, or typed text, and nothing
/// is written to disk. Requesting keyboard access is deliberately separate from
/// monitoring so no TCC prompt can appear without an explicit user action.
@MainActor
final class HerdrCommandKeyMonitor {
    typealias KeyStateQuery = @MainActor (CGEventSourceStateID, CGKeyCode) -> Bool
    typealias FlagsQuery = @MainActor (CGEventSourceStateID) -> UInt64
    typealias AccessQuery = @MainActor () -> Bool

    /// `kVK_Command` (55) is the left Command key; `kVK_RightCommand` (54) is the right.
    static let leftCommandKeyCode = CGKeyCode(kVK_Command)
    static let rightCommandKeyCode = CGKeyCode(kVK_RightCommand)
    /// Device-dependent bits carried by keyboard events; AppKit's `modifierFlags`
    /// masks these out, the Quartz flag table does not.
    static let leftCommandDeviceMask: UInt64 = 0x0000_0008
    static let rightCommandDeviceMask: UInt64 = 0x0000_0010

    private let keyStateQuery: KeyStateQuery
    private let flagsQuery: FlagsQuery
    private let listenEventAccess: AccessQuery
    private let requestListenEventAccess: AccessQuery

    private var globalMonitor: Any?
    private var isMonitoring = false
    private var isLeftObservedDown = false
    private var isRightObservedDown = false

    init(
        keyStateQuery: @escaping KeyStateQuery = { state, key in
            CGEventSource.keyState(state, key: key)
        },
        flagsQuery: @escaping FlagsQuery = { state in
            CGEventSource.flagsState(state).rawValue
        },
        listenEventAccess: @escaping AccessQuery = { CGPreflightListenEventAccess() },
        requestListenEventAccess: @escaping AccessQuery = { CGRequestListenEventAccess() }
    ) {
        self.keyStateQuery = keyStateQuery
        self.flagsQuery = flagsQuery
        self.listenEventAccess = listenEventAccess
        self.requestListenEventAccess = requestListenEventAccess
    }

    var isKeyboardAccessGranted: Bool { listenEventAccess() }

    /// Begins observing. Installs the global monitor only when keyboard access is
    /// already granted; the permission-free polls keep working either way.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        guard listenEventAccess() else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.observeFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
            }
        }
        // A monitor installed while either key is already held must not read the
        // next release as a press.
        isLeftObservedDown = keyStateQuery(.combinedSessionState, Self.leftCommandKeyCode)
        isRightObservedDown = keyStateQuery(.combinedSessionState, Self.rightCommandKeyCode)
    }

    func stopMonitoring() {
        isMonitoring = false
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        isLeftObservedDown = false
        isRightObservedDown = false
    }

    /// User-initiated only. Called from the App Shots settings control.
    @discardableResult
    func requestKeyboardAccess() -> Bool {
        requestListenEventAccess()
    }

    func currentState() -> HerdrCommandKeyState {
        let isLeftFromKeyState = keyStateQuery(.combinedSessionState, Self.leftCommandKeyCode)
        // Always query both keys: a false left result must not starve the right read.
        let isRightFromKeyState = keyStateQuery(.combinedSessionState, Self.rightCommandKeyCode)
        let flags = flagsQuery(.combinedSessionState)
        let isLeftFromFlags = flags & Self.leftCommandDeviceMask != 0
        let isRightFromFlags = flags & Self.rightCommandDeviceMask != 0

        let isLeft = isLeftObservedDown || isLeftFromKeyState || isLeftFromFlags
        let isRight = isRightObservedDown || isRightFromKeyState || isRightFromFlags
        return HerdrCommandKeyState(
            isLeftCommandPressed: isLeft,
            isRightCommandPressed: isRight,
            signal: signal(
                isLeftObserved: isLeftObservedDown,
                isRightObserved: isRightObservedDown,
                isLeftFromKeyState: isLeftFromKeyState,
                isRightFromKeyState: isRightFromKeyState,
                isLeftFromFlags: isLeftFromFlags,
                isRightFromFlags: isRightFromFlags
            )
        )
    }

    /// A press is reported by the strongest signal that observed it, so the
    /// diagnostics readout names the mechanism that actually worked.
    private func signal(
        isLeftObserved: Bool,
        isRightObserved: Bool,
        isLeftFromKeyState: Bool,
        isRightFromKeyState: Bool,
        isLeftFromFlags: Bool,
        isRightFromFlags: Bool
    ) -> HerdrCommandKeySignal {
        if isLeftObserved || isRightObserved { return .globalMonitor }
        if isLeftFromKeyState || isRightFromKeyState { return .keyState }
        if isLeftFromFlags || isRightFromFlags { return .flagsState }
        return .unavailable
    }

    /// One `flagsChanged` event identifies exactly which Command key changed. A
    /// missing generic Command bit means no Command key is held at all, which
    /// resynchronizes both sides after any event the monitor could not observe.
    private func observeFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard isMonitoring else { return }
        guard flags.contains(.command) else {
            isLeftObservedDown = false
            isRightObservedDown = false
            return
        }
        switch Int(keyCode) {
        case Int(Self.leftCommandKeyCode):
            isLeftObservedDown.toggle()
        case Int(Self.rightCommandKeyCode):
            isRightObservedDown.toggle()
        default:
            break
        }
    }

    isolated deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}
