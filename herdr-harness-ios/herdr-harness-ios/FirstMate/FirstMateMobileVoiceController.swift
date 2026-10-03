import Foundation
import Observation

/// The recorder does not own its transcription Task. This controller owns the
/// cancellation chain and returns recognized text to the original draft.
/// Sending always remains a separate composer action.
@MainActor @Observable
final class FirstMateMobileVoiceController {
    let capture = HerdrQuickVoiceCapture()
    private var demoPhase: HerdrQuickVoiceCapture.Phase = .idle
    private var demoStarted: Date?
    private var demo = false
    private(set) var hint: String?
    private(set) var diagnosticReport: String?
    private(set) var startPulse = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: Session?

    @MainActor private final class Session {
        let id = UUID()
        let store: FirstMateStore
        let context: FirstMateStore.OperationContext
        let material: FirstMateMobileComposerDraft
        let revision: Int
        let initialText: String
        let isCurrent: @MainActor () -> Bool
        var retainsResult = true
        init(store: FirstMateStore, material: FirstMateMobileComposerDraft,
             isCurrent: @escaping @MainActor () -> Bool) {
            self.store = store; self.material = material; context = store.operationContext
            revision = material.revision; initialText = store.composerDraft(for: context)
            self.isCurrent = isCurrent
        }
    }

    var phase: HerdrQuickVoiceCapture.Phase { demo ? demoPhase : capture.phase }
    var samples: [CGFloat] { demo ? [0.2, 0.45, 0.7, 0.4, 0.9, 0.6, 0.3, 0.5] : capture.samples }

    func begin(store: FirstMateStore, material: FirstMateMobileComposerDraft,
               isCurrent: @escaping @MainActor () -> Bool) {
        guard phase == .idle, task == nil, isCurrent(), !material.blocksSending else { return }
        session = Session(store: store, material: material, isCurrent: isCurrent)
        demo = store.isDemo; hint = nil; diagnosticReport = nil; startPulse &+= 1
        if demo {
            demoStarted = .now
            demoPhase = .locked
        } else {
            capture.beginLocked()
        }
    }

    func finish() {
        guard let session, phase == .recording || phase == .locked, task == nil else { return }
        if demo { demoPhase = .transcribing }
        task = Task { [weak self] in
            guard let self else { return }
            let outcome: HerdrQuickVoiceCapture.Outcome
            if self.demo {
                if let failure = Self.diagnosticDemoFailure {
                    self.diagnosticReport = failure.report
                    outcome = .failure(failure.localizedDescription)
                } else if Date.now.timeIntervalSince(self.demoStarted ?? .now) < HerdrQuickVoiceCapture.minimumDuration {
                    outcome = .tooShort
                } else {
                    outcome = .transcript(.init(text: "Please summarize the next step.", provider: .demo, language: nil, usedFallback: false))
                }
            } else {
                outcome = await self.capture.endHold { url in
                    do {
                        return try await Self.transcribe(url, store: session.store, context: session.context,
                            isCurrent: session.isCurrent)
                    } catch let failure as VoiceTranscriptionFailure {
                        self.diagnosticReport = failure.report
                        throw failure
                    }
                }
            }
            guard self.session?.id == session.id else { return }
            self.task = nil; self.session = nil; self.demoPhase = .idle
            switch outcome {
            case .transcript(let transcript):
                guard session.retainsResult else { return }
                let attached = session.material.receiveVoice(transcript.text, initialRevision: session.revision,
                    initialText: session.initialText, store: session.store, context: session.context)
                if attached { self.hint = "Dictation added. Review your message, then tap Send." }
            case .tooShort: self.hint = "Nothing heard. Tap the mic and speak a little longer."
            case .failure(let message):
                self.hint = self.diagnosticReport == nil ? message
                    : "Transcription failed. Open Transcription details for the failed steps. Record again to retry."
            case .cancelled: self.hint = "Recording cancelled."
            }
        }
    }

    private static var diagnosticDemoFailure: VoiceTranscriptionFailure? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-HerdrVoiceDiagnosticFailure") else { return nil }
        return try? .combined(
            privateError: APIError.server(status: 503, message: "Synthetic provider failure", code: "transcription_unavailable"),
            appleError: VoiceTranscriptionFailure.wrapping(VoiceTranscriptionError.deviceUnavailable, stage: .appleDevice))
        #else
        return nil
        #endif
    }

    func clearHint() { hint = nil; diagnosticReport = nil }

    func cancel(preserveRecognizedText: Bool = false) {
        session?.retainsResult = preserveRecognizedText
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
