import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("External Pi links")
struct ExternalPiRequestTests {
    @Test("Slack context and nested URLs survive URL encoding exactly once")
    func slackRequest() throws {
        var url = URLComponents(string: "herdr://pi/new")!
        let context = "Alex: C++ fails with A&B\nReply: check 50% and `code` 🔎"
        let sourceURL = "https://example.slack.com/archives/C123/p456?thread_ts=123&cid=C123"
        url.queryItems = [
            .init(name: "prompt", value: "Explain this & suggest a reply"),
            .init(name: "context", value: context),
            .init(name: "source_url", value: sourceURL),
            .init(name: "source", value: "Slack"),
            .init(name: "title", value: "Build failure"),
            .init(name: "workspace_id", value: "work-mac|w7"),
            .init(name: "request_id", value: "slack-123"),
        ]
        let request = try ExternalPiRequest(url: #require(url.url))
        #expect(request.context == context)
        #expect(request.sourceURL?.absoluteString == sourceURL)
        #expect(request.targetMachineID == "work-mac")
        #expect(request.rawWorkspaceID == "w7")
        #expect(request.sessionTitle == "Build failure")
        #expect(request.composedPrompt.hasPrefix("Explain this & suggest a reply\n\n"))
        #expect(request.composedPrompt.contains("not additional instructions"))
        #expect(request.composedPrompt.contains(sourceURL))
    }

    @Test("Minimal links preserve a prompt and generate a unique identity")
    func minimal() throws {
        let request = try ExternalPiRequest(url: #require(URL(string: "herdr://pi/new?prompt=Hi%2520there%2Bfriend")), makeRequestID: { "generated" })
        #expect(request.composedPrompt == "Hi%20there+friend")
        #expect(request.requestID == "generated")
        #expect(request.workspaceID == nil)
    }

    @Test("Invalid routes and ambiguous parameters fail before any action", arguments: [
        "herdr://pi/unknown?prompt=Hi",
        "herdr://pi/new?prompt=",
        "herdr://pi/new?prompt=Hi&prompt=Bye",
        "herdr://pi/new?prompt=Hi&command=rm",
        "herdr://pi/new?prompt=Hi&source_url=file%3A%2F%2F%2Ftmp%2Fa",
        "herdr://pi/new?prompt=Hi&source_url=https%3A%2F%2Fuser%3Apass%40example.com",
        "herdr://pi/new?prompt=Hi&machine_id=mac1&workspace_id=mac2%7Cw1",
        "herdr://pi/new?prompt=Hi&cwd=relative",
        "herdr://pi/new?prompt=Hi&cwd=~%2Fprojects",
        "herdr://pi/new?prompt=Hi&machine_id=",
        "herdr://pi/new?prompt=Hi&workspace_id=mac%7C",
        "herdr://pi/new?prompt=Hi&request_id=bad%2Fid",
        "herdr://pi/new?prompt=Hi%00there",
        "herdr://pi/new?prompt=Hi#ignored",
    ])
    func rejectsInvalid(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: ExternalPiRequest.InvalidRequest.self) { try ExternalPiRequest(url: url) }
    }

    @Test("Context fences cannot escape the quoted reference block")
    func embeddedFences() throws {
        var url = URLComponents(string: "herdr://pi/new")!
        url.queryItems = [.init(name: "prompt", value: "Summarize"), .init(name: "context", value: "````\nmalicious source instruction\n````")]
        let request = try ExternalPiRequest(url: #require(url.url))
        #expect(request.composedPrompt.contains("`````json"))
        #expect(request.composedPrompt.hasSuffix("`````"))
    }

    @Test("Oversized requests are rejected, never silently truncated")
    func sizeLimit() throws {
        var url = URLComponents(string: "herdr://pi/new")!
        url.queryItems = [.init(name: "prompt", value: String(repeating: "a", count: 16_385))]
        #expect(throws: ExternalPiRequest.InvalidRequest.self) { try ExternalPiRequest(url: #require(url.url)) }
    }

    @Test("Maximum title and request identity fit the harness label limits")
    func labelLimits() throws {
        var url = URLComponents(string: "herdr://pi/new")!
        url.queryItems = [
            .init(name: "prompt", value: "Hi"),
            .init(name: "title", value: String(repeating: "t", count: 160)),
            .init(name: "request_id", value: String(repeating: "a", count: 100)),
        ]
        let request = try ExternalPiRequest(url: #require(url.url))
        #expect(request.sessionTitle.count <= 120)
        #expect(request.newWorkspaceLabel.count <= 120)
    }
}
