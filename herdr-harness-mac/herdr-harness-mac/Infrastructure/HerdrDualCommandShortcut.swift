import AppKit

/// Polls device-specific modifier bits so left-Command + right-Command can be
/// observed without consuming key events or installing an accessibility event tap.
@MainActor
final class HerdrDualCommandShortcut {
    static let leftCommandMask: UInt = 0x0000_0008
    static let rightCommandMask: UInt = 0x0000_0010

    private let flagsProvider: @MainActor () -> UInt
    private let handler: @MainActor () -> Void
    private var timer: Timer?
    private var wasPressed = false
    private(set) var registrationGeneration = 0

    init(
        flagsProvider: @escaping @MainActor () -> UInt = { NSEvent.modifierFlags.rawValue },
        handler: @escaping @MainActor () -> Void
    ) {
        self.flagsProvider = flagsProvider
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
                self?.sampleCurrentFlags(ifRegistrationGeneration: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Registering while the keys are already held must not turn one
        // physical chord into a second capture after disable/re-enable.
        wasPressed = Self.isChordPressed(flagsProvider())
        return true
    }

    func unregister() {
        registrationGeneration &+= 1
        timer?.invalidate()
        timer = nil
        wasPressed = false
    }

    /// Kept internal as a deterministic state-machine seam for unit tests.
    func sample(flags: UInt) {
        let isPressed = Self.isChordPressed(flags)
        if isPressed, !wasPressed {
            handler()
        }
        wasPressed = isPressed
    }

    /// Generation-checking makes stale callbacks inert after unregister or a
    /// later registration.
    func sampleCurrentFlags(ifRegistrationGeneration generation: Int) {
        guard timer != nil, registrationGeneration == generation else { return }
        sample(flags: flagsProvider())
    }

    private static func isChordPressed(_ flags: UInt) -> Bool {
        let chordMask = leftCommandMask | rightCommandMask
        return flags & chordMask == chordMask
    }

    isolated deinit {
        timer?.invalidate()
    }
}
