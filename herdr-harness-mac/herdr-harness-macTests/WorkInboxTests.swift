import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Work inbox")
struct WorkInboxTests {
    @Test("Decodes provider sections and prioritizes active Jira statuses")
    func decodesAndPrioritizes() throws {
        let response = try JSONDecoder().decode(
            WorkInboxResponse.self,
            from: Data(
                """
                {
                  "ok": true,
                  "review_requests": {
                    "ok": true,
                    "items": [{
                      "number": 1,
                      "title": "Add calculator drawer",
                      "url": "https://github.com/example-org/garden-planner/pull/1",
                      "is_draft": false,
                      "state": "open",
                      "author": "contributor-a",
                      "repository": "example-org/garden-planner"
                    }]
                  },
                  "jira_tickets": {
                    "ok": true,
                    "items": [
                      {"key":"APP-1","title":"Backlog","status":"Backlog","priority":"","issue_type":"Story","url":"https://jira.example/APP-1"},
                      {"key":"APP-2","title":"Review","status":"In Code Review","priority":"","issue_type":"Story","url":"https://jira.example/APP-2"},
                      {"key":"APP-3","title":"Other","status":"Ready for QA","priority":"","issue_type":"Story","url":"https://jira.example/APP-3"},
                      {"key":"APP-4","title":"Active","status":"In Progress","priority":"","issue_type":"Story","url":"https://jira.example/APP-4"},
                      {"key":"APP-5","title":"Blocked","status":"Blocked","priority":"","issue_type":"Story","url":"https://jira.example/APP-5"}
                    ]
                  }
                }
                """.utf8
            )
        )

        let prioritized = response.prioritizingActiveJiraStatuses()

        #expect(prioritized.reviewRequests.items.first?.number == 1)
        #expect(prioritized.reviewRequests.items.first?.repository == "example-org/garden-planner")
        #expect(prioritized.jiraTickets.items.map(\.key) == ["APP-4", "APP-2", "APP-5", "APP-1", "APP-3"])
    }

    @Test("Rejects non-web work item links")
    func validatesBrowserLinks() {
        let review = GitHubReviewRequest(
            number: 1,
            title: "Unsafe",
            url: "file:///tmp/private",
            isDraft: false,
            state: "open",
            author: "author",
            repository: "owner/repo"
        )
        let ticket = JiraTicket(
            key: "APP-1",
            projectKey: "APP",
            title: "Unsafe",
            status: "In Progress",
            priority: "High",
            issueType: "Story",
            url: "herdr://pane/private"
        )

        #expect(review.browserURL == nil)
        #expect(ticket.workInboxURL == nil)
    }

    @Test("Store keeps provider results and reports transport failures")
    @MainActor
    func storeRefreshState() async {
        let store = WorkInboxStore()
        let identity = identity()
        store.configure(identity: identity)
        var response = WorkInboxResponse.empty
        response.reviewRequests.items = [
            GitHubReviewRequest(
                number: 7,
                title: "Review me",
                url: "https://github.com/owner/repo/pull/7",
                isDraft: false,
                state: "open",
                author: "author",
                repository: "owner/repo"
            )
        ]

        await store.refresh(for: identity) { response }

        #expect(store.hasLoaded)
        #expect(store.totalCount == 1)
        #expect(store.transportError == nil)

        await store.refresh(for: identity) { throw APIError.invalidResponse }

        #expect(store.totalCount == 1)
        #expect(store.transportError == "The Herdr server returned an invalid response.")
    }

    @Test("A provider failure retains its last successful rows and freshness")
    @MainActor
    func providerFailureKeepsLastGoodRows() async {
        let store = WorkInboxStore()
        let identity = identity()
        store.configure(identity: identity)
        await store.refresh(for: identity) { response(number: 9) }
        let updatedAt = store.reviewRequestsUpdatedAt
        var failure = WorkInboxResponse.empty
        failure.reviewRequests.ok = false
        failure.jiraTickets.items = [.init(key: "APP-2", projectKey: "APP", title: "Task", status: "In Progress", priority: "", issueType: "Story", url: "https://jira.example/APP-2")]
        await store.refresh(for: identity) { failure }
        #expect(store.response.reviewRequests.items.map(\.number) == [9])
        #expect(store.reviewRequestsUpdatedAt == updatedAt)
        #expect(store.error(for: .github) != nil)
        #expect(store.response.jiraTickets.items.map(\.key) == ["APP-2"])
        #expect(store.jiraTicketsUpdatedAt != nil)
        #expect(store.error(for: .jira) == nil)
        await store.refresh(for: identity) { .empty }
        #expect(store.response.reviewRequests.items.isEmpty)
        #expect(store.error(for: .github) == nil)
    }

    @Test("A delayed old primary cannot overwrite new data or finish its refresh")
    @MainActor
    func replacementRejectsOldResponseAndDefer() async {
        let store = WorkInboxStore()
        let old = identity()
        let new = identity(generation: 1)
        let oldGate = InboxResponseGate()
        let newGate = InboxResponseGate()
        store.configure(identity: old)
        let first = Task { await store.refresh(for: old) { await oldGate.load() } }
        await oldGate.waitUntilRequested()
        store.configure(identity: new)
        #expect(!store.hasLoaded)
        #expect(store.response.reviewRequests.items.isEmpty)
        let second = Task { await store.refresh(for: new) { await newGate.load() } }
        await newGate.waitUntilRequested()
        oldGate.finish(response(number: 1))
        await first.value
        #expect(store.isRefreshing)
        #expect(!store.hasLoaded)
        newGate.finish(response(number: 2))
        await second.value
        #expect(store.response.reviewRequests.items.map(\.number) == [2])
        #expect(!store.isRefreshing)
    }

    @Test("Automatic refreshes wait out the minimum interval, but an explicit refresh does not")
    @MainActor
    func minimumInterval() async {
        let store = WorkInboxStore()
        let first = identity()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var loads = 0
        store.configure(identity: first)
        await store.refresh(for: first, minimumInterval: 60, now: start) { throw URLError(.cancelled) }
        await store.refresh(for: first, minimumInterval: 60, now: start) { loads += 1; return response(number: 1) }
        #expect(loads == 1, "A cancelled load does not start the interval")
        await store.refresh(for: first, minimumInterval: 60, now: start.addingTimeInterval(30)) { loads += 1; return response(number: 2) }
        #expect(loads == 1)
        await store.refresh(for: first, now: start.addingTimeInterval(31)) { loads += 1; return response(number: 3) }
        #expect(loads == 2)
        await store.refresh(for: first, minimumInterval: 60, now: start.addingTimeInterval(95)) { loads += 1; return response(number: 4) }
        #expect(loads == 3)
        #expect(store.response.reviewRequests.items.map(\.number) == [4])
        let replacement = identity(generation: 1)
        store.configure(identity: replacement)
        await store.refresh(for: replacement, minimumInterval: 60, now: start.addingTimeInterval(96)) { loads += 1; return response(number: 5) }
        #expect(loads == 4, "A new primary loads at once")
    }

    @Test("Cancelled loads do not publish a result or an error banner")
    @MainActor
    func ignoresCancellation() async {
        let store = WorkInboxStore()
        let identity = identity()
        store.configure(identity: identity)
        await store.refresh(for: identity) { throw URLError(.cancelled) }
        #expect(!store.hasLoaded)
        #expect(store.transportError == nil)
        let gate = InboxResponseGate()
        let task = Task { await store.refresh(for: identity) { await gate.load() } }
        await gate.waitUntilRequested()
        task.cancel()
        gate.finish(response(number: 3))
        await task.value
        #expect(!store.hasLoaded)
        #expect(store.response.reviewRequests.items.isEmpty)
        #expect(store.transportError == nil)
    }

    private func identity(generation: Int = 0) -> WorkInboxConnectionIdentity {
        .init(machineID: "primary", generation: generation, isDemo: false,
              connection: .init(configuration: ServerConfiguration(urlString: "https://companion.example", token: "synthetic")!, generation: generation))
    }

    private func response(number: Int) -> WorkInboxResponse {
        var response = WorkInboxResponse.empty
        response.reviewRequests.items = [.init(number: number, title: "Review", url: "https://github.com/example/repo/pull/\(number)", isDraft: false, state: "open", author: "author", repository: "example/repo")]
        return response
    }

}


@MainActor
private final class InboxResponseGate {
    private var pending: CheckedContinuation<WorkInboxResponse, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func load() async -> WorkInboxResponse {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ response: WorkInboxResponse) { pending?.resume(returning: response); pending = nil }
}
