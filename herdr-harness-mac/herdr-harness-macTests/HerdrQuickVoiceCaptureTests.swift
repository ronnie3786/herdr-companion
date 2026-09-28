import AVFoundation
import Foundation
import Testing
@testable import herdr_harness_mac

/// Deterministic coverage for `HerdrQuickVoiceCapture` using the recorder's
/// existing fake-engine seam: no microphone, audio device, or system
/// permission prompt is touched.
@Suite("Quick voice capture lifecycle", .serialized)
@MainActor
struct HerdrQuickVoiceCaptureTests {
    @Test("A locked capture transcribes once and resets to idle")
    func lockedCaptureTranscribesOnce() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        #expect(harness.capture.phase == .locked)
        #expect(harness.capture.recorderStatus == .recording)
        try #require(harness.engine).currentTime = 1.4

        let outcome = await harness.capture.endHold(transcribe: harness.transcribe)

        #expect(outcome == .transcript(VoiceTranscription(
            text: "Synthetic transcript",
            provider: .demo,
            language: nil,
            usedFallback: false
        )))
        #expect(harness.capture.phase == .idle)
        #expect(harness.transcribeCount == 1)
        #expect(harness.capture.recorderStatus == .idle)
    }

    @Test("A repeated finish cannot transcribe the same recording twice")
    func repeatedFinishTranscribesOnce() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        try #require(harness.engine).currentTime = 1.2

        let first = await harness.capture.endHold(transcribe: harness.transcribe)
        let second = await harness.capture.endHold(transcribe: harness.transcribe)

        #expect(first != .cancelled)
        #expect(second == .cancelled)
        #expect(harness.transcribeCount == 1)
    }

    @Test("A recorder that already finished automatically still transcribes once")
    func automaticCompletionStillTranscribes() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        let engine = try #require(harness.engine)
        engine.currentTime = 2.2

        // The recorder's duration limit ends capture while the phase stays
        // locked; the finish path must still produce exactly one transcript.
        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.capture.recorderStatus == .finished)
        #expect(harness.capture.phase == .locked)

        let outcome = await harness.capture.endHold(transcribe: harness.transcribe)
        #expect(outcome != .cancelled)
        #expect(harness.transcribeCount == 1)
        #expect(harness.capture.phase == .idle)
    }

    @Test("A capture shorter than the minimum is discarded without transcribing")
    func tooShortCaptureIsDiscarded() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        try #require(harness.engine).currentTime = 0.1

        let outcome = await harness.capture.endHold(transcribe: harness.transcribe)

        #expect(outcome == .tooShort)
        #expect(harness.transcribeCount == 0)
        #expect(harness.capture.phase == .idle)
        #expect(harness.capture.recorderStatus == .idle)
    }

    @Test("A transcription failure surfaces and resets the capture")
    func transcriptionFailureResets() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        try #require(harness.engine).currentTime = 1.1

        let outcome = await harness.capture.endHold { _ in
            throw VoiceTranscriptionError.emptyTranscript
        }

        guard case let .failure(message) = outcome else {
            Issue.record("Expected a failure outcome, got \(outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(harness.capture.phase == .idle)
        #expect(harness.capture.recorderStatus == .idle)
    }

    @Test("Cancel discards the recording and a later finish does nothing")
    func cancelDiscards() async throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        #expect(harness.capture.recorderStatus == .recording)

        harness.capture.cancel()
        #expect(harness.capture.phase == .idle)
        #expect(harness.capture.recorderStatus == .idle)

        let outcome = await harness.capture.endHold(transcribe: harness.transcribe)
        #expect(outcome == .cancelled)
        #expect(harness.transcribeCount == 0)
    }

    @Test("A second begin while a capture is active is ignored")
    func secondBeginIsIgnored() throws {
        let harness = QuickCaptureHarness()
        harness.capture.beginLocked()
        harness.capture.beginLocked()

        #expect(harness.engines.count == 1)
        #expect(harness.capture.phase == .locked)
    }

    @Test("Locking notifies the host exactly when the capture starts")
    func lockCallbackFires() {
        let harness = QuickCaptureHarness()
        var lockCount = 0
        harness.capture.onLock = { lockCount += 1 }

        harness.capture.beginLocked()
        harness.capture.beginLocked()

        #expect(lockCount == 1)
    }
}

// MARK: - Harness

@MainActor
final class QuickCaptureHarness {
    let recorder: HerdrVoiceRecorder
    let capture: HerdrQuickVoiceCapture
    private(set) var engines: [FakeQuickVoiceEngine] = []
    private(set) var transcribeCount = 0

    init() {
        recorder = HerdrVoiceRecorder()
        capture = HerdrQuickVoiceCapture(recorder: recorder)
        // Authorization is injected so no system prompt or real capture runs.
        recorder.microphoneAuthorizationStatus = { .authorized }
        recorder.makeRecordingEngine = { [weak self] url, _ in
            // `applyCompleteProtection` expects the prepared file to exist.
            try Data().write(to: url)
            let engine = FakeQuickVoiceEngine()
            self?.engines.append(engine)
            return engine
        }
    }

    var engine: FakeQuickVoiceEngine? { engines.last }

    func transcribe(_ url: URL) async throws -> VoiceTranscription {
        transcribeCount += 1
        return VoiceTranscription(text: "Synthetic transcript", provider: .demo, language: nil, usedFallback: false)
    }
}

final class FakeQuickVoiceEngine: HerdrRecordingEngine {
    var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    var isRecording = false
    var currentTime: TimeInterval = 0

    func prepareToRecord() -> Bool { true }

    func record(forDuration duration: TimeInterval) -> Bool {
        isRecording = true
        return true
    }

    func stop() {
        isRecording = false
    }

    func updateMeters() {}

    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
}
