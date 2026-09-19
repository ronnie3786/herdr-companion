import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Issue report models")
struct IssueReportModelsTests {
    @Test("The request encodes exactly the server's keys")
    func requestEncodesExactKeys() throws {
        let request = IssueReportRequest(
            kind: .feature,
            title: "Add a dark sidebar",
            body: "  verbatim body\n",
            autofix: true,
            environment: ["client": "herdr-companion-mac", "app_version": "0.20.0"],
            attachments: [
                IssueReportAttachmentBody(filename: "shot.png", contentType: "image/png", dataBase64: "iVBORw0="),
            ],
            clientReportId: "3f2b9c1e-7a4d-4e8f-9b0c-1d2e3f4a5b6c"
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["kind", "title", "body", "autofix", "environment", "attachments", "clientReportId"])
        #expect(object["kind"] as? String == "feature")
        #expect(object["title"] as? String == "Add a dark sidebar")
        #expect(object["body"] as? String == "  verbatim body\n")
        #expect(object["autofix"] as? Bool == true)
        #expect(object["environment"] as? [String: String] == ["client": "herdr-companion-mac", "app_version": "0.20.0"])
        #expect(object["clientReportId"] as? String == "3f2b9c1e-7a4d-4e8f-9b0c-1d2e3f4a5b6c")

        let attachments = try #require(object["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(Set(attachments[0].keys) == ["filename", "contentType", "dataBase64"])
        #expect(attachments[0]["contentType"] as? String == "image/png")
        #expect(attachments[0]["dataBase64"] as? String == "iVBORw0=")
    }

    @Test("Bug reports encode their kind as \"bug\"")
    func bugKindEncodes() throws {
        let request = IssueReportRequest(
            kind: .bug, title: "t", body: "b", autofix: false, environment: [:], attachments: [], clientReportId: "bug-report-01"
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["kind"] as? String == "bug")
        #expect(object["autofix"] as? Bool == false)
        #expect((object["attachments"] as? [Any])?.isEmpty == true)
        #expect(object["clientReportId"] as? String == "bug-report-01")
    }

    @Test("The submit response decodes the full server payload")
    func responseDecodesFullPayload() throws {
        let json = """
        {"ok": true, "report": {
            "id": "isr_0123456789ab", "kind": "bug", "title": "Crash on launch", "autofix": true,
            "issueNumber": 42, "issueUrl": "https://github.com/owner/repo/issues/42",
            "repository": "owner/repo",
            "attachments": [
                {"filename": "shot.png",
                 "url": "https://github.com/owner/repo/releases/download/issue-attachments/isr_0123456789ab-shot.png",
                 "contentType": "image/png", "size": 1234}
            ],
            "createdAt": "2026-09-18T12:00:00Z"
        }}
        """
        let response = try JSONDecoder().decode(IssueReportResponse.self, from: Data(json.utf8))

        #expect(response.ok)
        #expect(response.report.id == "isr_0123456789ab")
        #expect(response.report.kind == .bug)
        #expect(response.report.title == "Crash on launch")
        #expect(response.report.autofix)
        #expect(response.report.issueNumber == 42)
        #expect(response.report.issueUrl == "https://github.com/owner/repo/issues/42")
        #expect(response.report.repository == "owner/repo")
        #expect(response.report.createdAt == "2026-09-18T12:00:00Z")
        #expect(response.report.attachments == [
            IssueReportUploadedAttachment(
                filename: "shot.png",
                url: "https://github.com/owner/repo/releases/download/issue-attachments/isr_0123456789ab-shot.png",
                contentType: "image/png",
                size: 1234
            ),
        ])
    }

    @Test("The submit response tolerates missing descriptive fields")
    func responseToleratesMissingFields() throws {
        let json = #"{"ok":true,"report":{"id":"isr_1","issueNumber":7,"issueUrl":"https://github.com/owner/repo/issues/7"}}"#
        let response = try JSONDecoder().decode(IssueReportResponse.self, from: Data(json.utf8))

        #expect(response.report.issueNumber == 7)
        #expect(response.report.kind == .bug)
        #expect(response.report.title.isEmpty)
        #expect(!response.report.autofix)
        #expect(response.report.repository.isEmpty)
        #expect(response.report.attachments.isEmpty)
        #expect(response.report.createdAt.isEmpty)
    }

    @Test("A response without an issue number is rejected")
    func responseRequiresIssueNumber() {
        let json = #"{"ok":true,"report":{"id":"isr_1","issueUrl":"https://github.com/owner/repo/issues/7"}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IssueReportResponse.self, from: Data(json.utf8))
        }
    }

    @Test("Capabilities decode the server payload")
    func capabilitiesDecode() throws {
        let json = """
        {"ok": true, "available": true, "repository": "owner/repo", "reason": null,
         "maxAttachments": 4, "maxAttachmentBytes": 1048576, "maxTotalAttachmentBytes": 2097152,
         "attachmentHosting": "release-assets", "publicRepository": true,
         "labels": {"report": "herdr-app-report", "autofix": "herdr-autofix"}}
        """
        let capabilities = try JSONDecoder().decode(IssueReportCapabilities.self, from: Data(json.utf8))

        #expect(capabilities == IssueReportCapabilities(
            ok: true,
            available: true,
            repository: "owner/repo",
            reason: nil,
            maxAttachments: 4,
            maxAttachmentBytes: 1_048_576,
            maxTotalAttachmentBytes: 2_097_152,
            publicRepository: true
        ))
    }

    @Test("Capabilities fall back to the documented defaults")
    func capabilitiesDefaults() throws {
        let json = #"{"ok":true,"available":false,"repository":null,"reason":"No repository is configured."}"#
        let capabilities = try JSONDecoder().decode(IssueReportCapabilities.self, from: Data(json.utf8))

        #expect(capabilities.ok)
        #expect(!capabilities.available)
        #expect(capabilities.repository == nil)
        #expect(capabilities.reason == "No repository is configured.")
        #expect(capabilities.maxAttachments == 6)
        #expect(capabilities.maxAttachmentBytes == 20 * 1024 * 1024)
        #expect(capabilities.maxTotalAttachmentBytes == 40 * 1024 * 1024)
        #expect(capabilities.publicRepository)

        let empty = try JSONDecoder().decode(IssueReportCapabilities.self, from: Data("{}".utf8))
        #expect(!empty.available)
        #expect(empty.maxAttachments == 6)
    }

    @Test("Server capabilities expose the issue-reports flag")
    func serverCapabilitiesFlag() throws {
        let decoder = JSONDecoder()
        let supported = try decoder.decode(
            ServerCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["pane-retirement-v1","issue-reports-v1"]}"#.utf8)
        )
        #expect(supported.supportsIssueReports)

        let unsupported = try decoder.decode(
            ServerCapabilities.self,
            from: Data(#"{"ok":true,"capabilities":["pane-retirement-v1"]}"#.utf8)
        )
        #expect(!unsupported.supportsIssueReports)

        let legacy = try decoder.decode(ServerCapabilities.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(!legacy.supportsIssueReports)
    }

    @Test("Kinds are identifiable by their wire value")
    func kindIdentity() {
        #expect(IssueReportKind.allCases.map(\.id) == ["bug", "feature"])
        #expect(IssueReportKind.bug.label == "Bug")
        #expect(IssueReportKind.feature.label == "Feature request")
    }
}
