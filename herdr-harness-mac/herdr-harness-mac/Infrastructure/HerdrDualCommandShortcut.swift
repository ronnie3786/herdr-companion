import AppKit

/// Watches the two Command keys so left-Command + right-Command can be a
/// shortcut without consuming either key from the frontmost app.
///
/// Detection itself lives in `HerdrCommandKeyMonitor`; this type owns only the
/// press/release lifecycle: fire once per physical press, rearm on release, and
/// ignore samples from a superseded registration.
@MainActor
final class HerdrDualCommandShortcut {
    typealias StateProvider = @MainActor () -> HerdrCommandKeyState

    private let stateProvider: StateProvider
    private let handler: @MainActor (HerdrCommandKeySignal) -> Void
    private var timer: Timer?
    private var wasPressed = false
    private(set) var registrationGeneration = 0

    init(
        stateProvider: @escaping StateProvider,
        handler: @escaping @MainActor (HerdrCommandKeySignal) -> Void
    ) {
        self.stateProvider = stateProvider
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
    func sample(state: HerdrCommandKeyState) {
        let isPressed = state.isChordPressed
        if isPressed, !wasPressed {
            handler(state.signal)
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
