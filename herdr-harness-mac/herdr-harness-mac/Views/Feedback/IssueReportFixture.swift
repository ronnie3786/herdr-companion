#if DEBUG
import Foundation

/// Deterministic, network-free doubles for the report sheet's UI tests.
///
/// Enabled only by an explicit `-HerdrIssueReportFixture` launch argument in a
/// DEBUG build. The fixture never contacts a companion, never opens the
/// microphone, and never files anything: an explicit **File report** still
/// takes the ordinary demo-mode path, which refuses to publish. Tests use it
/// to exercise the typed and dictated preparation paths with stable timing and
/// output instead of a live provider or device.
@MainActor
enum IssueReportUITestFixture {
    static let launchArgument = "-HerdrIssueReportFixture"
    /// Makes the first drafting request fail, so one explicit retry can be
    /// observed to recover.
    static let transientFailureArgument = "-HerdrIssueReportFixtureDraftFailure"

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }
    static var draftsFailOnce: Bool {
        ProcessInfo.processInfo.arguments.contains(transientFailureArgument)
    }

    /// Stable synthetic copy, independent of any provider or machine.
    static let transcript = "Synthetic dictated request for the smart input box."
    static let draftDelay: Duration = .milliseconds(1_200)
    /// Long enough for a UI test to observe the explicit transcribing state
    /// before the transcript lands; tests never depend on this value.
    static let transcriptionDelay: Duration = .milliseconds(900)
    static let syntheticRecordingURL = URL(fileURLWithPath: "/tmp/herdr-issue-report-fixture.wav")

    static func draftTitle(for kind: IssueReportKind) -> String {
        kind == .feature ? "Synthetic feature draft" : "Synthetic bug draft"
    }

    static func draftBody(for kind: IssueReportKind) -> String {
        let label = kind == .feature ? "feature" : "bug"
        return """
        ## Synthetic \(label) description

        This description was produced by the deterministic UI-test fixture for the \(label) form.
        """
    }

    static func makeDrafting() -> any IssueReportDrafting { FixtureDrafting() }

    static func makeCapture() -> any IssueReportVoiceCapturing { FixtureCapture() }

    static func makeTranscriber() -> IssueReportVoiceTranscriber {
        { _, _ in
            try await Task.sleep(for: transcriptionDelay)
            return transcript
        }
    }
}

@MainActor
private final class FixtureDrafting: IssueReportDrafting {
    private var attempts = 0

    func availability(for machineID: String) async -> IssueReportDraftAvailability { .available }

    func draft(
        kind: IssueReportKind,
        text: String,
        machineID: String
    ) async throws -> IssueReportDraftOutput {
        attempts += 1
        try await Task.sleep(for: IssueReportUITestFixture.draftDelay)
        if IssueReportUITestFixture.draftsFailOnce, attempts == 1 {
            throw IssueReportDraftError.runFailed("The synthetic drafting provider is unavailable.")
        }
        return IssueReportDraftOutput(
            title: IssueReportUITestFixture.draftTitle(for: kind),
            body: IssueReportUITestFixture.draftBody(for: kind)
        )
    }
}

/// An inline capture engine with the recorder's real state transitions — idle,
/// permission pending, and recording — but no audio device. `endCapture`
/// mirrors `HerdrVoiceRecorder.stopRecording`: it reports the finished capture
/// before the ordinary state notification so explicit Stop and an automatic
/// duration completion converge on one transcription.
@MainActor
private final class FixtureCapture: IssueReportVoiceCapturing {
    var isRequestingPermission = false
    var isRecording = false
    var hasTranscribableRecording = false
    var outputURL: URL?
    var errorMessage: String?
    var onStateChange: (() -> Void)?
    var onCaptureFinished: (() -> Void)?

    func beginCapture() {
        isRequestingPermission = false
        isRecording = true
        hasTranscribableRecording = false
        errorMessage = nil
        outputURL = IssueReportUITestFixture.syntheticRecordingURL
        onStateChange?()
    }

    func endCapture() {
        guard isRecording else { return }
        isRecording = false
        hasTranscribableRecording = true
        outputURL = IssueReportUITestFixture.syntheticRecordingURL
        onCaptureFinished?()
        onStateChange?()
    }

    func discard() {
        isRequestingPermission = false
        isRecording = false
        hasTranscribableRecording = false
        outputURL = nil
        errorMessage = nil
        onStateChange?()
    }
}
#endif
