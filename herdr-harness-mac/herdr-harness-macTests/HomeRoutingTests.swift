import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home route ownership")
@MainActor
struct HomeRoutingTests {
    @Test("Chat routes use the exact scoped pane and reopen an already selected chat")
    func scopedChatAndRepeatedOpen() {
        let fixture = Fixture()
        fixture.model.workspaces = [workspace(machineID: "alpha"), workspace(machineID: "beta")]
        let target = MachineScopedID.compose(machineID: "alpha", rawID: "pane")
        fixture.model.selectedPaneID = target
        fixture.shell.show(.home, model: fixture.model)
        let previousFocus = fixture.shell.paneModeFocusRequest
        #expect(fixture.open(.chat(paneID: target)) == .opened)
        #expect(fixture.model.selectedPaneID == target)
        #expect(fixture.shell.detailScope == .session)
        #expect(fixture.shell.paneModeFocusRequest > previousFocus)
        fixture.shell.show(.home, model: fixture.model)
        #expect(fixture.open(.chat(paneID: "beta|pane")) == .opened)
        #expect(fixture.model.selectedPaneID == "beta|pane")
    }

    @Test("Missing scoped and raw chat targets never resolve to another machine")
    func missingChat() {
        let fixture = Fixture()
        fixture.model.workspaces = [workspace(machineID: "beta")]
        fixture.model.selectedPaneID = "beta|pane"
        fixture.shell.show(.home, model: fixture.model)
        if case .unavailable(let message) = fixture.open(.chat(paneID: "alpha|pane")) {
            #expect(message.contains("alpha"))
        } else { Issue.record("A missing owner must remain unavailable") }
        #expect(fixture.model.selectedPaneID == "beta|pane")
        #expect(fixture.shell.detailScope == .home)
        if case .unavailable = fixture.open(.chat(paneID: "pane")) {} else { Issue.record("Raw pane IDs must not route") }
    }

    @Test("First Mate links carry an exact source request and never use the fallback request")
    func exactFirstMate() throws {
        let fixture = Fixture()
        fixture.shell.firstMateChatOpenRequest = .init(machineID: "beta", featureID: "same")
        #expect(fixture.open(.firstMate(machineID: "alpha", featureID: "same")) == .opened)
        let request = try #require(fixture.shell.firstMateChatExactOpenRequest)
        #expect(request.target == .init(machineID: "alpha", featureID: "same"))
        #expect(request.identity.generation == fixture.model.connectionGeneration)
        #expect(request.identity.configuration == fixture.model.firstMateConfiguration(machineID: "alpha"))
        #expect(fixture.shell.firstMateChatOpenRequest == nil)
        #expect(fixture.windows == [HerdrWindowID.firstMateChat])
        fixture.open(.firstMate(machineID: "removed", featureID: "same"))
        #expect(fixture.shell.firstMateChatExactOpenRequest?.target.machineID == "removed")
        #expect(fixture.shell.firstMateChatExactOpenRequest?.identity.configuration == nil)
        fixture.open(.firstMateLead)
        #expect(fixture.shell.firstMateChatExactOpenRequest == nil)
        #expect(fixture.shell.firstMateChatOpenLeadRequest == 1)
    }

    @Test("Prepared review routing clears another owner's detail even for the same review ID")
    func exactPreparedReview() {
        let fixture = Fixture()
        fixture.shell.configurePRReviewIfNeeded(configuration: fixture.model.prReviewConfiguration(machineID: "alpha"),
            machineID: "alpha", connectionGeneration: fixture.model.connectionGeneration, isDemo: false)
        fixture.shell.prReview.select("same")
        #expect(fixture.open(.review(machineID: "beta", reviewID: "same")) == .opened)
        #expect(fixture.shell.prReview.currentMachineID == "beta")
        #expect(fixture.shell.prReview.selectedReviewID == "same")
        #expect(fixture.shell.prReview.snapshot == nil)
        #expect(fixture.shell.homeReviewRevealRequest?.target == .review(machineID: "beta", reviewID: "same"))
        #expect(fixture.shell.detailScope == .prReview)
        let firstReveal = fixture.shell.homeReviewRevealRequest?.id
        fixture.open(.review(machineID: "beta", reviewID: "same"))
        #expect(fixture.shell.homeReviewRevealRequest?.id != firstReveal)
        if case .unavailable(let message) = fixture.open(.review(machineID: "removed", reviewID: "same")) {
            #expect(message.contains("removed") && message.contains("same"))
        } else { Issue.record("A missing review machine must remain unavailable") }
        #expect(fixture.shell.prReview.currentMachineID == "removed")
        #expect(fixture.shell.homeReviewRevealRequest?.target == .review(machineID: "removed", reviewID: "same"))
    }

    @Test("Watcher and machine reveals retain the exact target on every repeated click")
    func reveals() {
        let fixture = Fixture()
        fixture.open(.watcher(machineID: "beta", watcherID: "same"))
        #expect(fixture.shell.detailScope == .watchers)
        #expect(fixture.shell.homeWatcherRevealRequest?.target == .watcher(machineID: "beta", watcherID: "same"))
        let first = fixture.shell.homeWatcherRevealRequest?.id
        fixture.open(.watcher(machineID: "beta", watcherID: "same"))
        #expect(fixture.shell.homeWatcherRevealRequest?.id != first)
        fixture.open(.machine(machineID: "removed"))
        #expect(fixture.settingsOpened == 1)
        #expect(fixture.shell.homeMachineRevealRequest?.target == .machine(machineID: "removed"))
        #expect(fixture.shell.homeMachineRevealRequest?.missingMessage.contains("removed") == true)
    }

    @Test("Canonical request routes require matching provider repository, number, host, and open state")
    func canonicalRequest() {
        let request = reviewRequest()
        #expect(HomeRouting.canonicalReviewRequest("https://github.com/sample/project/pull/41?tab=files#review", requests: [request])?.url
            == "https://github.com/sample/project/pull/41")
        for url in ["https://enterprise.example/sample/project/pull/41", "https://github.com/other/project/pull/41",
                    "https://github.com/sample/project/pull/42", "https://github.com/sample/project/pull/%34%31",
                    "javascript:alert(1)"] {
            #expect(HomeRouting.canonicalReviewRequest(url, requests: [request]) == nil)
        }
        var mismatched = request
        mismatched.repository = "other/project"
        #expect(HomeRouting.canonicalReviewRequest(request.url, requests: [mismatched]) == nil)
        var closed = request
        closed.state = "CLOSED"
        #expect(HomeRouting.canonicalReviewRequest(request.url, requests: [closed]) == nil)
    }

    @Test("A configured default opens only the preparation form and preserves its canonical URL across host configuration")
    func configuredDefault() async {
        let fixture = Fixture(defaultHost: "alpha")
        let request = reviewRequest()
        await fixture.loadRequests([request])
        fixture.shell.configurePRReviewIfNeeded(configuration: fixture.model.prReviewConfiguration(machineID: "beta"),
            machineID: "beta", connectionGeneration: fixture.model.connectionGeneration, isDemo: false)
        fixture.shell.prReview.pendingURL = "https://github.com/example/old/pull/9"
        #expect(fixture.open(.reviewRequest(url: request.url)) == .opened)
        #expect(fixture.shell.prReview.currentMachineID == "alpha")
        #expect(fixture.shell.prReview.pendingURL == "https://github.com/sample/project/pull/41")
        #expect(fixture.shell.prReview.isPresentingStartSheet)
        #expect(!fixture.shell.prReview.isCreating)
        #expect(fixture.shell.prReview.reviews.isEmpty)
        #expect(fixture.shell.homeReviewPreparation == nil)
    }

    @Test("No default requires an explicit host and waits for chooser dismissal before presenting the preparation form")
    func explicitHost() async throws {
        let fixture = Fixture()
        let request = reviewRequest()
        await fixture.loadRequests([request])
        #expect(fixture.open(.reviewRequest(url: request.url)) == .choosingReviewHost)
        #expect(!fixture.shell.prReview.isPresentingStartSheet)
        let chooser = try #require(fixture.shell.homeReviewPreparation)
        #expect(HomeRouting.chooseReviewHost("beta", request: chooser, model: fixture.model, shell: fixture.shell))
        #expect(fixture.shell.homeReviewPreparation == nil)
        #expect(!fixture.shell.prReview.isPresentingStartSheet)
        #expect(HomeRouting.finishReviewPreparation(model: fixture.model, shell: fixture.shell) == .opened)
        #expect(fixture.shell.prReview.currentMachineID == "beta")
        #expect(fixture.shell.prReview.pendingURL == "https://github.com/sample/project/pull/41")
        #expect(fixture.shell.prReview.isPresentingStartSheet)
        #expect(!fixture.shell.prReview.isCreating)
        #expect(HomeRouting.finishReviewPreparation(model: fixture.model, shell: fixture.shell) == nil)
    }

    @Test("A chosen host cannot silently change connection during sheet dismissal", arguments: ["generation", "endpoint", "removed"])
    func hostChanges(change: String) async throws {
        let fixture = Fixture()
        let request = reviewRequest()
        await fixture.loadRequests([request])
        fixture.open(.reviewRequest(url: request.url))
        let chooser = try #require(fixture.shell.homeReviewPreparation)
        #expect(HomeRouting.chooseReviewHost("beta", request: chooser, model: fixture.model, shell: fixture.shell))
        switch change {
        case "generation": fixture.model.connectionGeneration += 1
        case "endpoint": fixture.model.machines[1].urlString = "https://replacement.example"
        default: fixture.model.machines.removeAll { $0.id == "beta" }
        }
        let outcome = HomeRouting.finishReviewPreparation(model: fixture.model, shell: fixture.shell)
        if case .unavailable = outcome {} else { Issue.record("A changed host must reject preparation") }
        #expect(!fixture.shell.prReview.isPresentingStartSheet)
        #expect(fixture.shell.prReview.pendingURL == nil)
    }

    private func reviewRequest() -> GitHubReviewRequest {
        .init(number: 41, title: "Synthetic review request", url: "https://github.com/Sample/Project/pull/41",
              isDraft: false, state: "OPEN", author: "sample-author", repository: "Sample/Project")
    }

    private func workspace(machineID: String) -> HerdrWorkspace {
        let pane = HerdrPane(paneID: "pane", terminalID: "terminal", workspaceID: "workspace", tabID: "tab",
                            focused: false, agentStatus: .idle, revision: 1, cwd: nil, foregroundCWD: nil,
                            label: "Synthetic chat", title: nil, agent: nil, displayAgent: nil,
                            terminalTitle: nil, terminalTitleStripped: nil)
        return HerdrWorkspace(workspaceID: "workspace", number: 1, label: "Synthetic workspace", focused: false,
                              paneCount: 1, tabCount: 1, activeTabID: "tab", agentStatus: .idle, panes: [pane]).stamped(machineID: machineID)
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let model: HerdrAppModel
        let shell: HerdrShellState
        var windows: [String] = []
        var settingsOpened = 0

        init(defaultHost: String? = nil) {
            defaults = UserDefaults(suiteName: "HomeRoutingTests.\(UUID().uuidString)")!
            if let defaultHost { defaults.set(defaultHost, forKey: "herdr.prReview.machineID") }
            model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults,
                                  configuredMachines: [.init(id: "alpha", name: "Alpha", urlString: "https://alpha.example"),
                                                       .init(id: "beta", name: "Beta", urlString: "https://beta.example")])
            shell = HerdrShellState(userDefaults: defaults)
        }

        @discardableResult
        func open(_ route: HomeRoute) -> HomeRouting.Outcome {
            HomeRouting.open(route, model: model, shell: shell,
                             openWindow: { self.windows.append($0) }, openSettings: { self.settingsOpened += 1 })
        }

        func loadRequests(_ requests: [GitHubReviewRequest]) async {
            let identity = model.workInboxConnectionIdentity
            shell.workInbox.configure(identity: identity)
            await shell.workInbox.refresh(for: identity) {
                .init(ok: true, reviewRequests: .init(ok: true, items: requests, error: nil), jiraTickets: .empty)
            }
        }
    }
}
