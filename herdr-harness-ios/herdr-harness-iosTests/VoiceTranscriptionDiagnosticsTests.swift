import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Transcription failure diagnostics")
struct VoiceTranscriptionDiagnosticsTests {
    @Test("Both provider failures survive, with stage and actionable codes")
    func retainsBothFailures() async throws {
        do {
            _ = try await VoiceTranscriptionPipeline.run(preferPrivate: true,
                privateTranscription: {
                    throw APIError.server(status: 503, message: "private server detail", code: "transcription_unavailable")
                }, appleTranscription: {
                    throw try VoiceTranscriptionFailure.wrapping(VoiceTranscriptionError.deviceUnavailable, stage: .appleDevice)
                })
            Issue.record("Expected a transcription failure")
        } catch let failure as VoiceTranscriptionFailure {
            #expect(failure.issues.map(\.stage) == [.request, .appleDevice])
            #expect(failure.report.contains("HTTP 503, transcription_unavailable"))
            #expect(failure.report.contains("does not support the Apple SpeechTranscriber engine"))
            #expect(!failure.report.contains("private server detail"))
            #expect(!failure.report.contains("recording is still here"))
            #expect(failure.report.contains("App:") && failure.report.contains("OS:") && failure.report.contains("Reference:"))
        }
    }

    @Test("Network diagnostics never include request URLs, tokens, or arbitrary error text")
    func networkPrivacy() throws {
        let error = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://private.example.invalid/?token=secret-value")!,
            NSLocalizedDescriptionKey: "secret-value and transcript contents",
        ])
        let failure = try VoiceTranscriptionFailure.wrapping(error, stage: .request)
        #expect(failure.report.contains("NSURLErrorDomain -1001"))
        #expect(failure.report.contains("timed out"))
        #expect(!failure.report.contains("private.example") && !failure.report.contains("secret-value"))
        #expect(!failure.report.contains("transcript contents"))
    }

    @Test("Unknown server codes and NSError domains cannot inject private values")
    func untrustedErrorPrivacy() throws {
        for error: any Error in [
            APIError.server(status: 502, message: "sensitive-message", code: "sensitive-code"),
            NSError(domain: "sensitive-domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "sensitive-message"]),
        ] {
            let failure = try VoiceTranscriptionFailure.wrapping(error, stage: .appleRecognition)
            #expect(!failure.report.contains("sensitive"))
        }
    }

    @Test("Model download and recording-read stages retain safe native error codes")
    func nestedStages() throws {
        let original = try VoiceTranscriptionFailure.wrapping(
            NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSFilePathErrorKey: "/private/sensitive.wav"]),
            stage: .appleAudio)
        let nested = try VoiceTranscriptionFailure.wrapping(original, stage: .appleRecognition)
        #expect(nested == original)
        #expect(nested.report.contains("reading recording") && nested.report.contains("code 257"))
        #expect(!nested.report.contains("sensitive.wav"))
        let assets = try VoiceTranscriptionFailure.wrapping(URLError(.notConnectedToInternet), stage: .appleAssets)
        #expect(assets.report.contains("model download") && assets.report.contains("-1009"))
    }

    @Test("Cancellation is never reported as an unavailable provider")
    func cancelledRequest() async throws {
        do {
            _ = try await VoiceTranscriptionPipeline.run(preferPrivate: true,
                privateTranscription: { throw URLError(.cancelled) },
                appleTranscription: { Issue.record("Cancellation started Apple fallback"); throw VoiceTranscriptionError.emptyTranscript })
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(throws: CancellationError.self) {
            try VoiceTranscriptionFailure.wrapping(CancellationError(), stage: .request)
        }
    }

    @Test("Permission and unsupported hardware produce distinct guidance")
    func distinctAppleFailures() throws {
        let permission = try VoiceTranscriptionFailure.wrapping(VoiceTranscriptionError.speechPermissionDenied, stage: .applePermission)
        let hardware = try VoiceTranscriptionFailure.wrapping(VoiceTranscriptionError.deviceUnavailable, stage: .appleDevice)
        #expect(permission.report.contains("Settings > Privacy"))
        #expect(hardware.report.contains("device support"))
        #expect(!hardware.report.contains("requested language"))
    }
}
