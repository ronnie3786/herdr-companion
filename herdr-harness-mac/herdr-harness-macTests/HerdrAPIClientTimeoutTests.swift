import Foundation
import Testing
@testable import herdr_harness_mac

struct HerdrAPIClientTimeoutTests {
    @Test func toolRequestsAllowNativeOperationTimeouts() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/git", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/git/stage", method: "POST") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/git", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/git/commit-diff", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/git/stage", method: "POST") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/skills", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/files", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/jira/assigned", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/work-inbox", method: "GET") == 30)
    }

    @Test func uploadsAndStreamsKeepTheirLongerBudgets() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/attachments", method: "POST") == 90)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/voice/transcriptions", method: "POST") == 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/capabilities", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/prepare", method: "POST") == 150)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/speech", method: "POST") == 150)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/cleanup/runs/clr_1/apply", method: "POST") == 45)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/stream", method: "GET") == 24 * 60 * 60)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/events", method: "GET") == 24 * 60 * 60)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces", method: "GET") == 45)
    }

    @Test func firstMateWritesAndReadsHaveSeparateBudgets() {
        for path in ["/api/v1/first-mate/features", "/api/v1/first-mate/features/f1/messages", "/api/v1/first-mate/features/f1/actions"] {
            #expect(HerdrAPIClient.timeoutInterval(path: path, method: "POST") == 86_400)
            #expect(HerdrAPIClient.timeoutInterval(path: path, method: "GET") == 90)
        }
    }

    @Test func terminalMutationsOutliveNativeCommandBudget() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/send-text", method: "POST") == 45)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/send-keys", method: "POST") == 45)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/run", method: "POST") == 45)
    }

    @Test func statusReadsOutlivePeerAndNativeRequests() {
        for path in ["/api/v1/first-mate/features", "/api/v1/first-mate/features/f/overview",
                     "/api/v1/first-mate/features/events", "/api/v1/first-mate/lead", "/api/v1/first-mate/sessions/s"] {
            #expect(HerdrAPIClient.timeoutInterval(path: path, method: "GET") == 90)
        }
        for path in ["/api/v1/health", "/api/v1/network"] {
            #expect(HerdrAPIClient.timeoutInterval(path: path, method: "GET") == 30)
        }
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p/pi/prompt", method: "POST") > 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/first-mate/features/f/messages", method: "POST") == 86_400)
    }

    @Test func roleFilesAllowLargeTransfers() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-roles/export", method: "GET") == 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-roles/import", method: "POST") == 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-roles", method: "GET") == 45)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-roles", method: "POST") == 45)
    }
}
