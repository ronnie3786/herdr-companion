import Foundation

/// How the report sheet presents one exact smart-input state.
///
/// Pure mappings so the deterministic unit tests can pin the distinctions the
/// rendered UI tests cannot see: the glow follows actual capture only (never a
/// pending permission request), the inline control's accessible label and
/// symbol match the one action it offers, progress copy is explicit, and the
/// preparation notice names the companion while keeping publication tied to
/// **File report**.
enum IssueReportSmartInputPresentation {
    /// Capture evidence, not a permission request. Reduce Motion changes only
    /// the pulse, never this answer.
    static func isGlowing(voiceState: IssueReportSmartInput.VoiceState) -> Bool {
        voiceState == .recording
    }

    static func micSymbol(voiceState: IssueReportSmartInput.VoiceState) -> String {
        switch voiceState {
        case .recording: "stop.fill"
        case .requestingPermission: "xmark"
        case .transcribing: "waveform"
        case .idle, .failed: "mic.fill"
        }
    }

    /// Accessibility never depends on the glow: the label names the one action
    /// the control will take in every non-transcribing state.
    static func micAccessibilityLabel(voiceState: IssueReportSmartInput.VoiceState) -> String {
        switch voiceState {
        case .recording: "Stop recording"
        case .requestingPermission: "Cancel recording"
        case .transcribing: "Transcribing recording"
        case .idle, .failed: "Record a description"
        }
    }

    /// The one-line status beside the inline control, or nil at rest. An error
    /// has its own actionable notice instead of a status line.
    static func statusText(
        isDrafting: Bool,
        voiceState: IssueReportSmartInput.VoiceState
    ) -> String? {
        if isDrafting { return "Drafting with AI…" }
        return switch voiceState {
        case .idle, .failed: nil
        case .requestingPermission: "Waiting for microphone permission…"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        }
    }

    /// Names the companion that prepares drafts and states plainly what leaves
    /// this Mac, so the optional AI step is never confused with filing.
    static func preparationNotice(companionName: String?) -> String {
        let trimmed = companionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let companion = trimmed.isEmpty ? "the selected companion" : trimmed
        return "Prepared by \(companion) using its configured Pi and transcription services. "
            + "Your text and recordings are not published — only File report files the issue."
    }
}
