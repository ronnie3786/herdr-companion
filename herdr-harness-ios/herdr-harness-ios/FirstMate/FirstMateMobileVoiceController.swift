import Foundation
import Observation

/// The recorder does not own its transcription Task. This controller owns the
/// cancellation chain and the one explicit authorization to submit its result.
@MainActor @Observable
final class FirstMateMobileVoiceController {
    let capture = HerdrQuickVoiceCapture()
    private var demoPhase: HerdrQuickVoiceCapture.Phase = .idle
    private var demoStarted: Date?
    private var demo = false
    private(set) var hint: String?
    private(set) var startPulse = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    @ObservationIgnored private var session: Session?

    @MainActor private final class Session {
        let id = UUID()
        let store: FirstMateStore
        let context: FirstMateStore.OperationContext
        let material: FirstMateMobileComposerDraft
        let revision: Int
        let initialText: String
        let isCurrent: @MainActor () -> Bool
        let submit: @MainActor () -> Bool
        var allowsSend = true
        var retainsResult = true
        init(store: FirstMateStore, material: FirstMateMobileComposerDraft,
             isCurrent: @escaping @MainActor () -> Bool, submit: @escaping @MainActor () -> Bool) {
            self.store = store; self.material = material; context = store.operationContext
            revision = material.revision; initialText = store.composerDraft(for: context)
            self.isCurrent = isCurrent; self.submit = submit
        }
    }

    var phase: HerdrQuickVoiceCapture.Phase { demo ? demoPhase : capture.phase }
    var samples: [CGFloat] { demo ? [0.2, 0.45, 0.7, 0.4, 0.9, 0.6, 0.3, 0.5] : capture.samples }

    func begin(store: FirstMateStore, material: FirstMateMobileComposerDraft, locked: Bool = false,
               isCurrent: @escaping @MainActor () -> Bool, submit: @escaping @MainActor () -> Bool) {
        guard phase == .idle, task == nil, isCurrent(), !material.blocksSending else { return }
        session = Session(store: store, material: material, isCurrent: isCurrent, submit: submit)
        demo = store.isDemo; hint = nil; startPulse &+= 1
        if demo {
            demoStarted = .now; demoPhase = locked ? .locked : .recording
            if !locked {
                lockTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.65))
                    guard !Task.isCancelled, let self, self.demoPhase == .recording else { return }
                    self.demoPhase = .locked
                }
            }
        } else if locked { capture.beginLocked() } else { capture.beginHold() }
    }

    func quickTap() { hint = "Hold the mic to talk." }

    func finish(explicitSend: Bool) {
        guard let session, phase == .recording || phase == .locked, task == nil else { return }
        session.allowsSend = session.allowsSend && explicitSend
        lockTask?.cancel(); lockTask = nil
        if demo { demoPhase = .transcribing }
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: HerdrQuickVoiceCapture.Outcome
            if self.demo {
                if Date.now.timeIntervalSince(self.demoStarted ?? .now) < HerdrQuickVoiceCapture.minimumDuration {
                    outcome = .tooShort
                } else {
                    outcome = .transcript(.init(text: "Please summarize the next step.", provider: .demo, language: nil, usedFallback: false))
                }
            } else {
                outcome = await self.capture.endHold { url in
                    try await Self.transcribe(url, store: session.store, context: session.context,
                        isCurrent: session.isCurrent)
                }
            }
            guard self.session?.id == session.id else { return }
            self.task = nil; self.session = nil; self.demoPhase = .idle
            switch outcome {
            case .transcript(let transcript):
                guard session.retainsResult else { return }
                let attached = session.material.receiveVoice(transcript.text, initialRevision: session.revision,
                    initialText: session.initialText, store: session.store, context: session.context)
                // Even a transport that ignores cancellation cannot authorize a send.
                if attached && session.allowsSend && !Task.isCancelled && session.isCurrent() {
                    if !session.submit() { self.hint = "Transcript saved in this conversation's draft." }
                } else if attached { self.hint = "Transcript saved in this conversation's draft." }
            case .tooShort: self.hint = "Nothing heard. Hold the mic a little longer."
            case .failure(let message): self.hint = message
            case .cancelled: self.hint = "Recording cancelled."
            }
        }
    }

    func cancel(preserveRecognizedText: Bool = false) {
        session?.allowsSend = false
        session?.retainsResult = preserveRecognizedText
        lockTask?.cancel(); lockTask = nil
        task?.cancel()
        capture.cancel()
        if task == nil { session = nil; demoPhase = .idle }
        hint = "Recording cancelled."
    }

    /// Check cancellation before *both* providers. A revoked owner is a
    /// cancellation, so it must never start the Apple fallback.
    static func transcribe(_ url: URL, store: FirstMateStore, context: FirstMateStore.OperationContext,
                           isCurrent: @escaping @MainActor () -> Bool,
                           apple: @escaping @Sendable (URL) async throws -> VoiceTranscription = { url in
                               let text = try await AppleVoiceTranscriber.transcribe(fileURL: url)
                               return .init(text: text, provider: .apple, language: nil, usedFallback: false)
                           }) async throws -> VoiceTranscription {
        try await VoiceTranscriptionPipeline.run(preferPrivate: true, privateTranscription: {
            try Task.checkCancellation()
            let allowed = await MainActor.run { isCurrent() && store.operationContext == context }
            guard allowed else { throw CancellationError() }
            let response = try await store.transcribeVoice(at: url, expectedContext: context)
            return .init(text: response.text, provider: response.backend == "parakeet" ? .parakeet : .server,
                         language: response.language, usedFallback: false)
        }, appleTranscription: {
            try Task.checkCancellation()
            let allowed = await MainActor.run { isCurrent() && store.operationContext == context }
            guard allowed else { throw CancellationError() }
            return try await apple(url)
        })
    }
}
