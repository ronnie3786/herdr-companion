import AVFoundation
import Foundation
import Testing
@testable import herdr_harness_mac

/// Deterministic coverage for the recorder's engine seam and capture
/// lifecycle: an injectable engine means preparation/start failures and
/// delayed completion callbacks are exercised without a microphone, audio
/// device, or real recording.
@Suite("Voice recorder engine lifecycle", .serialized)
@MainActor
struct HerdrVoiceRecorderTests {
    @Test("A failed preparation reports an actionable error and cleans up")
    func failedPreparation() throws {
        let harness = RecorderHarness(prepareResult: false)

        harness.recorder.startRecording()

        #expect(harness.recorder.status == .idle)
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.errorMessage?.contains("could not start recording") == true)
        #expect(harness.finishCount == 0)
        #expect(harness.recorder.outputURL == nil)
        let engine = try #require(harness.engines.first)
        #expect(engine.stopCount == 1)
        let attemptedURL = try #require(harness.firstURL)
        #expect(!FileManager.default.fileExists(atPath: attemptedURL.path))
    }

    @Test("A failed record start reports an actionable error and cleans up")
    func failedRecord() throws {
        let harness = RecorderHarness(recordResult: false)

        harness.recorder.startRecording()

        #expect(harness.recorder.status == .idle)
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.errorMessage?.contains("could not start recording") == true)
        #expect(harness.finishCount == 0)
        #expect(harness.recorder.outputURL == nil)
        let engine = try #require(harness.engines.first)
        #expect(engine.stopCount == 1)
        let attemptedURL = try #require(harness.firstURL)
        #expect(!FileManager.default.fileExists(atPath: attemptedURL.path))
    }

    @Test("Stop finishes once and ignores the delayed delegate callback")
    func stopIgnoresDelayedCallback() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        #expect(harness.recorder.isRecording)
        let engine = try #require(harness.engines.first)
        engine.currentTime = 1.5

        harness.recorder.stopRecording()
        #expect(harness.recorder.status == .finished)
        #expect(harness.finishCount == 1)

        // The real AVAudioRecorder often invokes its delegate just after
        // Stop; the stale callback must not transcribe a second time.
        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.finishCount == 1)
        #expect(harness.recorder.status == .finished)
    }

    @Test("The automatic duration completion finishes once")
    func automaticCompletionFinishesOnce() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        let engine = try #require(harness.engines.first)
        engine.currentTime = 2

        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.recorder.status == .finished)
        #expect(harness.finishCount == 1)

        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.finishCount == 1)
    }

    @Test("A callback after dismissal is ignored")
    func dismissalIgnoresObsoleteCallback() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        let engine = try #require(harness.engines.first)

        // The smart-input adapter discards the recorder on dismissal.
        harness.recorder.discard()
        #expect(harness.recorder.status == .idle)

        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.recorder.status == .idle)
        #expect(harness.finishCount == 0)
        #expect(harness.recorder.outputURL == nil)
    }

    @Test("A callback after a target change is ignored")
    func targetChangeIgnoresObsoleteCallback() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        let engine = try #require(harness.engines.first)

        // `IssueReportSmartInput.configure` discards retained audio when the
        // selected companion changes.
        harness.recorder.discard()
        harness.recorder.startRecording()
        let replacement = try #require(harness.engines.last)

        harness.recorder.handleCaptureFinished(engine, successfully: true)
        #expect(harness.recorder.isRecording)
        #expect(harness.recorder.status == .recording)
        #expect(harness.finishCount == 0)

        replacement.currentTime = 1
        harness.recorder.stopRecording()
        #expect(harness.finishCount == 1)
        #expect(harness.recorder.status == .finished)
    }

    @Test("A stale callback cannot finish a restarted capture")
    func restartIgnoresObsoleteCallback() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        let first = try #require(harness.engines.first)

        // Starting again discards the old attempt and begins a new engine.
        harness.recorder.startRecording()
        let second = try #require(harness.engines.last)
        #expect(second !== first)
        #expect(harness.recorder.isRecording)

        harness.recorder.handleCaptureFinished(first, successfully: true)
        #expect(harness.recorder.isRecording)
        #expect(harness.recorder.status == .recording)
        #expect(harness.finishCount == 0)

        second.currentTime = 1
        harness.recorder.stopRecording()
        #expect(harness.finishCount == 1)
        #expect(harness.recorder.status == .finished)
    }

    @Test("A failed completion reports the failure without transcribing")
    func failedCompletionDoesNotTranscribe() throws {
        let harness = RecorderHarness()
        harness.recorder.startRecording()
        let engine = try #require(harness.engines.first)

        harness.recorder.handleCaptureFinished(engine, successfully: false)
        #expect(harness.recorder.status == .idle)
        #expect(harness.recorder.errorMessage == "Recording failed.")
        #expect(harness.finishCount == 0)
    }

    @Test("A denied permission request never starts an engine")
    func deniedPermissionNeverStartsAnEngine() async throws {
        let harness = RecorderHarness()
        harness.recorder.microphoneAuthorizationStatus = { .notDetermined }
        harness.recorder.requestMicrophoneAccess = { false }

        harness.recorder.startRecording()
        #expect(harness.recorder.isRequestingPermission)
        try await waitUntil("permission resolved") { !harness.recorder.isRequestingPermission }

        #expect(harness.engines.isEmpty)
        #expect(harness.recorder.status == .idle)
        #expect(harness.recorder.errorMessage?.contains("required") == true)
        #expect(harness.finishCount == 0)
    }
}

// MARK: - Harness

@MainActor
private final class RecorderHarness {
    let recorder: HerdrVoiceRecorder
    private(set) var engines: [FakeRecordingEngine] = []
    private(set) var firstURL: URL?
    private(set) var finishCount = 0

    init(prepareResult: Bool = true, recordResult: Bool = true) {
        recorder = HerdrVoiceRecorder()
        recorder.microphoneAuthorizationStatus = { .authorized }
        recorder.makeRecordingEngine = { [weak self] url, _ in
            // `applyCompleteProtection` expects the prepared file to exist;
            // the fake engine never touches the audio device.
            try Data().write(to: url)
            if self?.firstURL == nil {
                self?.firstURL = url
            }
            let engine = FakeRecordingEngine(prepareResult: prepareResult, recordResult: recordResult)
            self?.engines.append(engine)
            return engine
        }
        recorder.onCaptureFinished = { [weak self] in self?.finishCount += 1 }
    }
}

private final class FakeRecordingEngine: HerdrRecordingEngine {
    var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    var isRecording = false
    var currentTime: TimeInterval = 0
    var prepareResult: Bool
    var recordResult: Bool
    private(set) var stopCount = 0

    init(prepareResult: Bool, recordResult: Bool) {
        self.prepareResult = prepareResult
        self.recordResult = recordResult
    }

    func prepareToRecord() -> Bool {
        prepareResult
    }

    func record(forDuration duration: TimeInterval) -> Bool {
        isRecording = recordResult
        return recordResult
    }

    func stop() {
        stopCount += 1
        isRecording = false
    }

    func updateMeters() {}

    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
