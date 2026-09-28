import Foundation

/// A complete sample of one recording's timeline. The audio clock owns time;
/// neither SwiftUI nor WebKit accumulates a second animation clock.
struct PRReviewGuideAnnotationFrame: Encodable, Sendable {
    let generation: String
    let sequence: Int
    let time: Double
    let cues: [PRReviewTimedCue]
    var reducedMotion = false
}

/// Window-owned transport that keeps 30 Hz samples out of SwiftUI observation.
@MainActor
final class PRReviewGuideAnnotationChannel {
    private var enabled = true
    private weak var view: PRReviewDiffTextView?
    private var request: (targets: [PRReviewGuideTarget], generation: String, completion: (Bool) -> Void)?
    private var frame: PRReviewGuideAnnotationFrame?
    private var preparedIdentity: String?
    private var preparationInFlight = false
    private var completedPreparation = false
    private var timeout: Task<Void, Never>?

    func install(_ view: PRReviewDiffTextView) {
        if self.view !== view {
            self.view?.clearGuideAnnotations()
            self.view = view
            preparedIdentity = nil
            preparationInFlight = false
        }
        view.setGuideAnnotationsEnabled(enabled)
        flush()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        view?.setGuideAnnotationsEnabled(enabled)
    }

    func prepare(targets: [PRReviewGuideTarget], generation: String, completion: @escaping (Bool) -> Void) {
        view?.clearGuideAnnotations()
        frame = nil
        timeout?.cancel()
        request = (targets, generation, completion)
        completedPreparation = false
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.request?.generation == generation else { return }
            self.complete(available: false)
        }
        preparedIdentity = nil
        preparationInFlight = false
        flush()
    }

    func update(_ frame: PRReviewGuideAnnotationFrame) {
        guard frame.generation == request?.generation else { return }
        self.frame = frame
        if preparedIdentity == view?.renderedIdentity { view?.sendGuideFrame(frame) }
    }

    func clear() {
        timeout?.cancel()
        timeout = nil
        request = nil
        frame = nil
        preparedIdentity = nil
        preparationInFlight = false
        view?.clearGuideAnnotations()
    }

    func rendered() {
        view?.setGuideAnnotationsEnabled(enabled)
        if preparedIdentity != view?.renderedIdentity { preparationInFlight = false }
        flush()
    }

    func ready(identity: String, generation: String, available: Bool) {
        guard let request, request.generation == generation, identity == view?.renderedIdentity else { return }
        preparationInFlight = false
        preparedIdentity = identity
        if let frame { view?.sendGuideFrame(frame) }
        complete(available: available)
    }

    private func complete(available: Bool) {
        guard !completedPreparation else { return }
        completedPreparation = true
        timeout?.cancel()
        timeout = nil
        request?.completion(available)
    }

    private func flush() {
        guard let view, let identity = view.renderedIdentity, let request,
              preparedIdentity != identity, !preparationInFlight,
              request.targets.allSatisfy({ $0.path == view.renderedGuidePath }) else { return }
        preparationInFlight = true
        view.prepareGuideAnnotations(targets: request.targets, generation: request.generation)
    }
}
