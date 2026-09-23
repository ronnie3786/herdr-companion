import Foundation

/// The client contract for the companion server's `issue-report-draft-v1`
/// Agent-run profile.
///
/// The profile is one-shot and tool-free: it receives only the chosen report
/// kind and the smart-input text, runs the execution machine's Pi default with
/// thinking Off for at most 60 seconds, and answers with exactly one JSON
/// object containing a title and a Markdown body. Every limit here mirrors
/// `herdr_harness/issue_report_drafts.py`; the server performs the
/// authoritative check on both the request and its own charter.
enum IssueReportDraftProfile {
    /// The profile name the companion must advertise before Herdr sends a
    /// drafting request. An older server without it keeps manual reporting.
    static let identifier = "issue-report-draft-v1"

    static let maxSourceCharacters = 20_000
    static let maxTitleCharacters = 200
    static let maxBodyCharacters = 20_000
    static let maxExecutionSeconds = 60
    static let deadline: Duration = .seconds(maxExecutionSeconds)
    static let pollInterval: Duration = .milliseconds(250)

    /// True when `text` contains a control character the draft profile refuses
    /// (every `Cc` scalar except tab, newline and carriage return). The server
    /// uses Python's `unicodedata.category`; this matches it.
    static func containsUnsupportedControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\n"
                && scalar != "\r"
                && scalar != "\t"
        }
    }

    /// Why `text` cannot be sent for drafting, excluding "blank" (an empty box
    /// is not an error state, it just disables the button). Mirrors the
    /// server's validation so an over-limit or control-bearing request is
    /// reported before a network call and never silently truncated.
    static func sourceProblem(_ text: String) -> IssueReportDraftError? {
        if text.unicodeScalars.count > maxSourceCharacters {
            return .sourceTooLong(maximum: maxSourceCharacters)
        }
        if containsUnsupportedControls(text) {
            return .sourceHasControlCharacters
        }
        return nil
    }
}

/// The exact request body accepted by `issue-report-draft-v1`.
///
/// The server rejects every other key, so a draft can never carry an
/// attachment, working directory, model override, system prompt, context
/// scope, pane, or continuation.
struct IssueReportDraftRequest: Encodable, Equatable, Sendable {
    let profile: String
    let kind: IssueReportKind
    let text: String

    init(kind: IssueReportKind, text: String) {
        profile = IssueReportDraftProfile.identifier
        self.kind = kind
        self.text = text
    }
}

/// The validated title and Markdown body returned by one drafting run.
struct IssueReportDraftOutput: Equatable, Sendable {
    let title: String
    let body: String
}

/// Why one drafting response could not be used. The reasons name the problem
/// without echoing raw model output back into the sheet.
enum IssueReportDraftOutputError: Error, Equatable, Sendable {
    case notAnObject
    case unexpectedFields
    case missingFields
    case invalidTypes
    case blankTitle
    case blankBody
    case titleHasControlCharacters
    case bodyHasControlCharacters
    case titleTooLong(maximum: Int)
    case bodyTooLong(maximum: Int)

    var reason: String {
        switch self {
        case .notAnObject:
            "the response was not one JSON object"
        case .unexpectedFields:
            "the response contained fields other than title and body"
        case .missingFields:
            "the response did not contain both a title and a body"
        case .invalidTypes:
            "the title and body were not both text"
        case .blankTitle:
            "the title was blank"
        case .blankBody:
            "the description was blank"
        case .titleHasControlCharacters:
            "the title contained control characters"
        case .bodyHasControlCharacters:
            "the description contained unsupported control characters"
        case let .titleTooLong(maximum):
            "the title was longer than \(maximum) characters"
        case let .bodyTooLong(maximum):
            "the description was longer than \(maximum.formatted()) characters"
        }
    }
}

extension IssueReportDraftOutput {
    /// Parses one drafting response into an apply-ready output.
    ///
    /// The response must be exactly one JSON object with exactly the string
    /// fields `title` and `body`. Everything else — a fence, commentary, a
    /// different type, a missing or blank field, control characters, or text
    /// over the report limits — is refused before anything touches the report.
    static func parse(_ response: String) throws -> IssueReportDraftOutput {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { throw IssueReportDraftOutputError.notAnObject }

        guard Set(fields.keys).isSubset(of: ["title", "body"]) else {
            throw IssueReportDraftOutputError.unexpectedFields
        }
        guard let rawTitle = fields["title"], let rawBody = fields["body"] else {
            throw IssueReportDraftOutputError.missingFields
        }
        guard let title = rawTitle as? String, let body = rawBody as? String else {
            throw IssueReportDraftOutputError.invalidTypes
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw IssueReportDraftOutputError.blankTitle }
        guard cleanTitle.unicodeScalars.count <= IssueReportDraftProfile.maxTitleCharacters else {
            throw IssueReportDraftOutputError.titleTooLong(maximum: IssueReportDraftProfile.maxTitleCharacters)
        }
        guard !cleanTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw IssueReportDraftOutputError.titleHasControlCharacters
        }

        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty else { throw IssueReportDraftOutputError.blankBody }
        guard cleanBody.unicodeScalars.count <= IssueReportDraftProfile.maxBodyCharacters else {
            throw IssueReportDraftOutputError.bodyTooLong(maximum: IssueReportDraftProfile.maxBodyCharacters)
        }
        // The applied description must survive the composer's own submission
        // check, so use exactly the same control-character rule.
        guard !IssueReportComposer.containsDisallowedControlCharacters(cleanBody) else {
            throw IssueReportDraftOutputError.bodyHasControlCharacters
        }

        return IssueReportDraftOutput(title: cleanTitle, body: cleanBody)
    }
}

/// Everything that can go wrong before a generated draft reaches the report.
/// Messages are actionable and never contain raw model output.
enum IssueReportDraftError: LocalizedError, Equatable, Sendable {
    case emptySource
    case sourceTooLong(maximum: Int)
    case sourceHasControlCharacters
    case noCompanion
    case unsupportedCompanion
    case companionUnavailable(String)
    case startFailed(String)
    case runFailed(String)
    case emptyOutput
    case invalidOutput(IssueReportDraftOutputError)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptySource:
            "Type what you want to report before drafting with AI."
        case let .sourceTooLong(maximum):
            "Keep the request to \(maximum.formatted()) characters. Your text is unchanged so you can edit it."
        case .sourceHasControlCharacters:
            "The request contains non-printable characters (such as terminal colour codes). Remove them to draft with AI."
        case .noCompanion:
            "Connect the companion server that should draft this report, then try again."
        case .unsupportedCompanion:
            "This machine's companion server doesn't support AI report drafting yet. "
                + "Update the companion server, then try again — you can still write the report by hand."
        case let .companionUnavailable(reason):
            "Couldn't reach the companion to draft this report. \(reason) Your request is unchanged; try again."
        case let .startFailed(reason):
            "The companion couldn't start AI drafting. \(reason) Your request is unchanged; try again."
        case let .runFailed(reason):
            "AI drafting failed on the companion. \(reason) Your request is unchanged; try again."
        case .emptyOutput:
            "AI drafting returned an empty response. Your request is unchanged; try again."
        case let .invalidOutput(reason):
            "AI drafting returned a response Herdr couldn't use because \(reason.reason). Your request is unchanged; try again."
        case .timedOut:
            "AI drafting took longer than \(IssueReportDraftProfile.maxExecutionSeconds) seconds and was stopped. "
                + "Your request is unchanged; try again."
        case .cancelled:
            "Drafting was cancelled."
        }
    }
}

/// Whether one exact companion can run the drafting profile. The smart-input
/// section disables only the AI action when drafting is unsupported; manual
/// reporting always stays available.
enum IssueReportDraftAvailability: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    case available
    /// The companion answered but does not advertise the drafting profile.
    case unsupportedCompanion
    /// The companion could not be reached or probed.
    case unavailable(String)

    var message: String? {
        switch self {
        case .unknown, .available:
            nil
        case .unsupportedCompanion:
            IssueReportDraftError.unsupportedCompanion.errorDescription
        case let .unavailable(reason):
            IssueReportDraftError.companionUnavailable(reason).errorDescription
        }
    }
}

/// The report identity a generated draft was requested against. A result is
/// applied only when the composer still matches every field, so a late or
/// cross-target completion can never overwrite newer edits.
struct IssueReportDraftToken: Equatable, Sendable {
    let revision: Int
    let kind: IssueReportKind
    let machineID: String
}
