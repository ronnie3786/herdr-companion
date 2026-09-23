import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Issue report draft contract", .serialized)
@MainActor
struct IssueReportDraftTests {
    @Test("The request encodes exactly profile, kind, and text")
    func requestEncodesOnlyAllowedFields() throws {
        let request = IssueReportDraftRequest(kind: .feature, text: "Add a quiet mode\nline two")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["profile", "kind", "text"])
        #expect(object["profile"] as? String == IssueReportDraftProfile.identifier)
        #expect(object["kind"] as? String == "feature")
        #expect(object["text"] as? String == "Add a quiet mode\nline two")
    }

    @Test("A well-formed response parses with outer whitespace trimmed")
    func parsesWellFormedOutput() throws {
        let output = try IssueReportDraftOutput.parse(
            #"{"title":"  Crash when opening two windows  ","body":"\n## Steps\n1. Open one window\n2. Open another\n\n"}"#
        )

        #expect(output.title == "Crash when opening two windows")
        #expect(output.body == "## Steps\n1. Open one window\n2. Open another")
    }

    @Test("Anything that is not one JSON object is refused")
    func refusesNonObjects() {
        let responses = [
            "",
            "   ",
            "Here is the issue you asked for:",
            "```json\n{\"title\":\"Title\",\"body\":\"Body\"}\n```",
            "[{\"title\":\"Title\",\"body\":\"Body\"}]",
            "\"Title\"",
            "42",
            "{\"title\":\"Title\",\"body\":\"Body\"} trailing commentary",
        ]
        for response in responses {
            #expect(throws: IssueReportDraftOutputError.notAnObject) {
                try IssueReportDraftOutput.parse(response)
            }
        }
    }

    @Test("Unexpected, missing, and mistyped fields are refused")
    func refusesMalformedObjects() {
        #expect(throws: IssueReportDraftOutputError.unexpectedFields) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":"Body","kind":"bug"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.missingFields) {
            try IssueReportDraftOutput.parse(#"{"title":"Title"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.missingFields) {
            try IssueReportDraftOutput.parse(#"{"body":"Body"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.invalidTypes) {
            try IssueReportDraftOutput.parse(#"{"title":7,"body":"Body"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.invalidTypes) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":null}"#)
        }
        #expect(throws: IssueReportDraftOutputError.invalidTypes) {
            try IssueReportDraftOutput.parse(#"{"title":["Title"],"body":"Body"}"#)
        }
    }

    @Test("Blank fields are refused")
    func refusesBlankFields() {
        #expect(throws: IssueReportDraftOutputError.blankTitle) {
            try IssueReportDraftOutput.parse(#"{"title":" \n\t ","body":"Body"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.blankBody) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":"\n\n"}"#)
        }
    }

    @Test("Control characters are refused in the title and the body")
    func refusesControlCharacters() {
        #expect(throws: IssueReportDraftOutputError.titleHasControlCharacters) {
            try IssueReportDraftOutput.parse(#"{"title":"Line\u000Abreak","body":"Body"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.bodyHasControlCharacters) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":"Body\u0000with NUL"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.bodyHasControlCharacters) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":"Body\u007Fdel"}"#)
        }
        // Tab, newline, and carriage return stay valid in a Markdown body.
        let output = try? IssueReportDraftOutput.parse(#"{"title":"Title","body":"first\nsecond\tthird\r"}"#)
        #expect(output?.body == "first\nsecond\tthird")
    }

    @Test("Oversized title and body are refused against the report limits")
    func refusesOversizedOutput() {
        let longTitle = String(repeating: "t", count: IssueReportDraftProfile.maxTitleCharacters + 1)
        let longBody = String(repeating: "b", count: IssueReportDraftProfile.maxBodyCharacters + 1)
        #expect(throws: IssueReportDraftOutputError.titleTooLong(maximum: IssueReportDraftProfile.maxTitleCharacters)) {
            try IssueReportDraftOutput.parse(#"{"title":"\#(longTitle)","body":"Body"}"#)
        }
        #expect(throws: IssueReportDraftOutputError.bodyTooLong(maximum: IssueReportDraftProfile.maxBodyCharacters)) {
            try IssueReportDraftOutput.parse(#"{"title":"Title","body":"\#(longBody)"}"#)
        }

        let exactTitle = String(repeating: "t", count: IssueReportDraftProfile.maxTitleCharacters)
        let exactBody = String(repeating: "b", count: IssueReportDraftProfile.maxBodyCharacters)
        let output = try? IssueReportDraftOutput.parse(#"{"title":"\#(exactTitle)","body":"\#(exactBody)"}"#)
        #expect(output?.title.count == IssueReportDraftProfile.maxTitleCharacters)
        #expect(output?.body.count == IssueReportDraftProfile.maxBodyCharacters)
    }

    @Test("The source policy matches the server: scalar cap and Cc controls")
    func sourcePolicy() {
        #expect(IssueReportDraftProfile.sourceProblem("plain English request") == nil)
        #expect(IssueReportDraftProfile.sourceProblem(String(repeating: "x", count: 20_000)) == nil)
        #expect(
            IssueReportDraftProfile.sourceProblem(String(repeating: "x", count: 20_001))
                == .sourceTooLong(maximum: 20_000)
        )

        #expect(!IssueReportDraftProfile.containsUnsupportedControls("line\nnext\ttab\rcarriage"))
        #expect(IssueReportDraftProfile.containsUnsupportedControls("bell\u{0007}"))
        #expect(IssueReportDraftProfile.containsUnsupportedControls("escape\u{001B}[31m"))
        #expect(IssueReportDraftProfile.containsUnsupportedControls("delete\u{007F}"))
        #expect(IssueReportDraftProfile.sourceProblem("bell\u{0007}") == .sourceHasControlCharacters)
    }

    @Test("Error messages keep typed text and name the upgrade path")
    func errorMessagesAreActionable() {
        let unsupported = IssueReportDraftError.unsupportedCompanion.errorDescription
        #expect(unsupported?.contains("Update the companion server") == true)
        #expect(unsupported?.contains("write the report by hand") == true)

        let unavailable = IssueReportDraftAvailability.unsupportedCompanion.message
        #expect(unavailable == unsupported)

        let overLimit = IssueReportDraftError.sourceTooLong(maximum: 20_000).errorDescription
        #expect(overLimit?.contains("unchanged") == true)

        let invalid = IssueReportDraftError.invalidOutput(.blankTitle).errorDescription
        #expect(invalid?.contains("the title was blank") == true)
        #expect(invalid?.contains("Your request is unchanged") == true)
    }
}
