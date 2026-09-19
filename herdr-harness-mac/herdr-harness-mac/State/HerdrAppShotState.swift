import AppKit

/// Which route asked for a window capture. Recorded so the App Shots
/// diagnostics can distinguish "the shortcut never fired" from "the capture
/// failed".
enum HerdrAppShotTrigger: String, Equatable, Sendable {
    case chord
    case hotKey
    case menu
    case settings

    var title: String {
        switch self {
        case .chord: "Both Command keys"
        case .hotKey: "⌃⌥C"
        case .menu: "File menu"
        case .settings: "Settings test"
        }
    }
}

/// The HUD-visible App Shots state. A capture is observable from the moment the
/// trigger fires, which is what makes a detection problem distinguishable from
/// an attachment problem.
enum HerdrAppShotStatus: Equatable, Sendable {
    case idle
    case capturing(startedAt: Date)
    case attached(filename: String)
    case failed(message: String)

    var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }
}

struct HerdrAppShotDiagnostics: Equatable, Sendable {
    var lastTriggerDate: Date?
    var lastTrigger: HerdrAppShotTrigger?
    var lastSignal: HerdrCommandKeySignal?
    var lastOutcome: String?
    var isChordRegistered = false
    var isHotKeyRegistered = false
    var isKeyboardAccessGranted = false
    var isScreenRecordingGranted = false
}

/// Presented state for the HUD notice. `nil` renders nothing, so an idle HUD is
/// unchanged.
struct HerdrHudAppShotNotice: Equatable {
    let title: String
    let symbol: String
    let isFailure: Bool

    static func notice(for status: HerdrAppShotStatus) -> HerdrHudAppShotNotice? {
        switch status {
        case .idle:
            return nil
        case .capturing:
            return HerdrHudAppShotNotice(
                title: "Capturing frontmost window…",
                symbol: "viewfinder",
                isFailure: false
            )
        case .attached:
            return HerdrHudAppShotNotice(
                title: "Screenshot added to New chat",
                symbol: "checkmark.circle",
                isFailure: false
            )
        case .failed(let message):
            return HerdrHudAppShotNotice(title: message, symbol: "exclamationmark.triangle", isFailure: true)
        }
    }

    /// Collapsed-hud form: one glyph that fits on the orb, where the full text
    /// cannot. Nil while capturing, because the orb already shows a capture ring.
    static func badge(for status: HerdrAppShotStatus) -> HerdrHudAppShotNotice? {
        switch status {
        case .idle, .capturing:
            return nil
        case .attached:
            return HerdrHudAppShotNotice(title: "Screenshot added to New chat", symbol: "checkmark", isFailure: false)
        case .failed:
            return HerdrHudAppShotNotice(title: "Capture failed", symbol: "exclamationmark", isFailure: true)
        }
    }
}

/// A macOS notification the App Shots path may post. The capture path never
/// prompts for permission; when notifications are not authorized the notice is
/// simply skipped and the HUD notice carries the information.
struct HerdrAppShotNotification: Equatable, Sendable {
    let title: String
    let body: String
    let isFailure: Bool

    static func detected() -> HerdrAppShotNotification {
        HerdrAppShotNotification(
            title: "Herdr App Shots",
            body: "Capturing the frontmost window…",
            isFailure: false
        )
    }

    static func failed(message: String) -> HerdrAppShotNotification {
        HerdrAppShotNotification(title: "Herdr App Shots couldn’t capture", body: message, isFailure: true)
    }
}

/// Chooses which process a capture should target. The HUD panel can own the
/// frontmost position, so the app remembers the last non-Herdr app and prefers
/// it over Herdr's own process.
enum HerdrAppShotTarget {
    static func processID(
        frontmostProcessID: pid_t?,
        lastExternalProcessID: pid_t?,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> pid_t? {
        guard let frontmostProcessID, frontmostProcessID != ownProcessID else {
            return lastExternalProcessID
        }
        return frontmostProcessID
    }
}

/// Single-line live readout for the App Shots settings control.
enum HerdrCommandKeyReadout {
    static func text(for state: HerdrCommandKeyState, keyboardAccessGranted: Bool) -> String {
        let left = state.isLeftCommandPressed ? "down" : "up"
        let right = state.isRightCommandPressed ? "down" : "up"
        let signal = state.signal == .unavailable && !keyboardAccessGranted
            ? "no signal yet — grant keyboard access if the shortcut stays silent"
            : state.signal.title.lowercased()
        return "Left ⌘ \(left) · Right ⌘ \(right) · \(signal)"
    }
}
