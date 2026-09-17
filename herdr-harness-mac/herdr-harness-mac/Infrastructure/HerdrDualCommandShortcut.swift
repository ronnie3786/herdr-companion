import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Polls the public Quartz key-state table so left-Command + right-Command can
/// be observed without consuming key events or installing an accessibility event tap.
@MainActor
final class HerdrDualCommandShortcut {
    struct State: Equatable {
        let isLeftCommandPressed: Bool
        let isRightCommandPressed: Bool

        var isChordPressed: Bool {
            isLeftCommandPressed && isRightCommandPressed
        }
    }

    typealias StateProvider = @MainActor () -> State
    typealias KeyStateQuery = @MainActor (CGEventSourceStateID, CGKeyCode) -> Bool

    static let leftCommandKeyCode = CGKeyCode(kVK_Command)
    static let rightCommandKeyCode = CGKeyCode(kVK_RightCommand)

    /// Central production provider shared by the shortcut and its controller.
    static var systemStateProvider: StateProvider {
        {
            state { sourceState, keyCode in
                CGEventSource.keyState(sourceState, key: keyCode)
            }
        }
    }

    /// Adapter seam for deterministic verification of the Quartz query contract.
    static func state(queryKeyState: KeyStateQuery) -> State {
        let leftPressed = queryKeyState(.combinedSessionState, leftCommandKeyCode)
        // Always query both keys. A false left result must not starve the right read.
        let rightPressed = queryKeyState(.combinedSessionState, rightCommandKeyCode)
        return State(
            isLeftCommandPressed: leftPressed,
            isRightCommandPressed: rightPressed
        )
    }

    private let stateProvider: StateProvider
    private let handler: @MainActor () -> Void
    private var timer: Timer?
    private var wasPressed = false
    private(set) var registrationGeneration = 0

    init(
        stateProvider: StateProvider? = nil,
        handler: @escaping @MainActor () -> Void
    ) {
        self.stateProvider = stateProvider ?? Self.systemStateProvider
        self.handler = handler
    }

    @discardableResult
    func register() -> Bool {
        guard timer == nil else { return true }
        registrationGeneration &+= 1
        let generation = registrationGeneration
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // The timer is installed only on the main run loop. Running the
            // sample inline avoids leaving a sampling task queued at unregister.
            MainActor.assumeIsolated {
                self?.sampleCurrentState(ifRegistrationGeneration: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Registering while the keys are already held must not turn one
        // physical chord into a second capture after disable/re-enable.
        wasPressed = stateProvider().isChordPressed
        return true
    }

    func unregister() {
        registrationGeneration &+= 1
        timer?.invalidate()
        timer = nil
        wasPressed = false
    }

    /// Kept internal as a deterministic state-machine seam for unit tests.
    func sample(state: State) {
        let isPressed = state.isChordPressed
        if isPressed, !wasPressed {
            handler()
        }
        wasPressed = isPressed
    }

    /// Generation-checking makes stale callbacks inert after unregister or a
    /// later registration.
    func sampleCurrentState(ifRegistrationGeneration generation: Int) {
        guard timer != nil, registrationGeneration == generation else { return }
        sample(state: stateProvider())
    }

    isolated deinit {
        timer?.invalidate()
    }
}
