import Foundation

/// One owner for speech or microphone capture across the app's windows.
/// Interruptions pause a guide, preserving its position for an explicit resume.
@MainActor
final class HerdrSpeechOwnership {
    static let shared = HerdrSpeechOwnership()
    /// Pending narration records this before synthesis so a later explicit
    /// microphone or Listen action wins over delayed autoplay.
    private(set) var claimGeneration = 0
    private var owner: UUID?
    private var interrupt: (() -> Void)?

    func claim(_ owner: UUID, interrupt: @escaping () -> Void) {
        guard self.owner != owner else { self.interrupt = interrupt; return }
        claimGeneration &+= 1
        let previous = self.interrupt
        self.owner = nil
        self.interrupt = nil
        previous?()
        self.owner = owner
        self.interrupt = interrupt
    }

    func release(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        interrupt = nil
    }
}
