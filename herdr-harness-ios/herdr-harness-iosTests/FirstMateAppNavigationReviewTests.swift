import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("First Mate app-boundary navigation review", .serialized)
@MainActor
struct FirstMateAppNavigationReviewTests {
    private func model() -> HerdrAppModel {
        let defaults = UserDefaults(suiteName: "AppNavigationReview.\(UUID())")!
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults,
                                  bootstrapMachines: [ChatFixtures.machine("alpha"), ChatFixtures.machine("beta")])
        model.hasCompletedSetup = true
        model.selectedTab = .notes
        return model
    }
    private func source(_ id: String, _ client: NavigationReviewClient, token: String = "synthetic") -> FirstMateMobileFleetSource {
        let machine = ChatFixtures.machine(id)
        return .init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: token), client: client)
    }
    private func request(_ feature: String, on host: String? = nil) throws -> FirstMateMobileOpenRequest {
        var components = URLComponents(string: "herdr://first-mate")!
        components.queryItems = [.init(name: "feature_id", value: feature)]
        if let host { components.queryItems?.append(.init(name: "server_url", value: "https://\(host).example.invalid")) }
        let url = try #require(components.url)
        return try #require(FirstMateMobileOpenRequest(url: url))
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "app navigation review") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Neither first response may claim an externally unqualified duplicate ID", arguments: ["alpha", "beta"])
    func partialFleet(_ first: String) async throws {
        let model = model(), a = NavigationReviewGate(), b = NavigationReviewGate()
        let alpha = NavigationReviewClient(ids: ["shared"], listGate: a)
        let beta = NavigationReviewClient(ids: ["shared"], listGate: b)
        let sources = [source("alpha", alpha), source("beta", beta)]
        model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration)
        let loading = Task { await model.firstMateFleet.refreshChatIndex() }
        defer { loading.cancel(); Task { await a.open(); await b.open() } }
        if first == "alpha" { await a.open() } else { await b.open() }
        try await wait { model.firstMateFleet.badgeCount == 1 }
        #expect(model.firstMateFleet.badgeCount == 1, "Partial healthy-host publication must remain independent")
        await model.openFirstMate(try request("shared"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget == nil)
        #expect(model.toastMessage?.contains("ownership") == true)
        #expect(model.selectedTab == .notes)
        await a.open(); await b.open(); await loading.value
        await model.openFirstMate(try request("shared"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget == nil, "Complete duplicate ownership still needs an explicit machine")
    }

    @Test("Before any first response, unknown ownership is explicit and exact/captured routes remain usable")
    func beforeFirstResponse() async throws {
        let model = model(), a = NavigationReviewGate(), b = NavigationReviewGate()
        let alpha = NavigationReviewClient(ids: ["shared"], listGate: a)
        let beta = NavigationReviewClient(ids: ["shared"], listGate: b)
        let sources = [source("alpha", alpha), source("beta", beta)]
        model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration)
        await model.openFirstMate(try request("shared"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget == nil)
        #expect(model.toastMessage?.contains("ownership") == true)
        await model.openFirstMate(try request("shared", on: "beta"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget == .init(machineID: "beta", featureID: "shared"))
        #expect(model.selectedTab == .firstMate)
        let captured = FirstMateFeatureTarget(machineID: "alpha", featureID: "earlier")
        #expect(await model.firstMateFleet.chat.navigate(try request("shared"), owner: captured, fleet: model.firstMateFleet))
        #expect(model.firstMateFleet.selectedTarget?.machineID == "alpha")
        let alphaCalls = await alpha.listCalls, betaCalls = await beta.listCalls
        #expect(alphaCalls == 0 && betaCalls == 0)
    }

    @Test("A failed or missing host inventory is not proof of unique ownership")
    func failedInventory() async throws {
        let model = model()
        let sources = [source("alpha", NavigationReviewClient(ids: ["shared"])),
                       source("beta", NavigationReviewClient(ids: [], failList: true))]
        model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration)
        await model.firstMateFleet.refreshChatIndex()
        #expect(model.firstMateFleet.badgeCount == 1)
        await model.openFirstMate(try request("shared"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget == nil)
        #expect(model.toastMessage?.contains("ownership") == true)
        await model.openFirstMate(try request("shared", on: "alpha"), sources: sources).value
        #expect(model.firstMateFleet.selectedTarget?.machineID == "alpha")
        #expect(model.selectedTab == .firstMate)
    }

    @Test("Bootstrap cannot overtake a newer exact link or manual selection", arguments: ["link", "feature", "lead"])
    func bootstrapSupersession(_ next: String) async throws {
        let model = model(), gate = NavigationReviewGate()
        let sources = [source("alpha", NavigationReviewClient(ids: ["old"], listGate: gate)),
                       source("beta", NavigationReviewClient(ids: ["new"]))]
        let old = model.openFirstMate(try request("old"), sources: sources)
        defer { old.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        let target = FirstMateFeatureTarget(machineID: "beta", featureID: "new")
        switch next {
        case "link": await model.openFirstMate(try request("new", on: "beta"), sources: sources).value
        case "feature": #expect(model.firstMateFleet.open(target))
        default: model.firstMateFleet.chat.select(.lead)
        }
        await gate.open(); await old.value
        if next == "lead" {
            #expect(model.firstMateFleet.chat.selection == .lead)
            #expect(model.firstMateFleet.selectedTarget == nil)
        } else {
            #expect(model.firstMateFleet.selectedTarget == target)
        }
        #expect(model.toastMessage == nil)
    }

    @Test("A superseded late bootstrap or detail error cannot annotate a newer route", arguments: [true, false], ["link", "feature", "lead"])
    func staleErrors(_ bootstrap: Bool, _ next: String) async throws {
        let model = model(), gate = NavigationReviewGate()
        let alpha = NavigationReviewClient(ids: ["old"], listGate: bootstrap ? gate : nil,
                                           detailGate: bootstrap ? nil : gate, failList: bootstrap, failDetail: !bootstrap)
        let sources = [source("alpha", alpha), source("beta", NavigationReviewClient(ids: ["new"]))]
        if !bootstrap { model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration) }
        let old = model.openFirstMate(try request("old", on: bootstrap ? nil : "alpha"), sources: sources)
        defer { old.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        let target = FirstMateFeatureTarget(machineID: "beta", featureID: "new")
        switch next {
        case "link": await model.openFirstMate(try request("new", on: "beta"), sources: sources).value
        case "feature": #expect(model.firstMateFleet.open(target))
        default: model.firstMateFleet.chat.select(.lead)
        }
        await gate.open(); await old.value
        if next == "lead" { #expect(model.firstMateFleet.chat.selection == .lead) }
        else { #expect(model.firstMateFleet.selectedTarget == target) }
        #expect(model.firstMateFleet.chat.routingError == nil)
        #expect(model.toastMessage == nil)
    }

    @Test("The latest queued intent wins before bootstrap and exact cold links do not wait on other inventories")
    func queuedIntents() async throws {
        let model = model(), gate = NavigationReviewGate()
        let alpha = NavigationReviewClient(ids: ["old"], listGate: gate)
        let beta = NavigationReviewClient(ids: ["new"], listGate: gate)
        let sources = [source("alpha", alpha), source("beta", beta)]
        let old = model.openFirstMate(try request("old"), sources: sources)
        let newer = model.openFirstMate(try request("new", on: "beta"), sources: sources)
        defer { old.cancel(); newer.cancel(); Task { await gate.open() } }
        // Neither queued task has run yet; the intent is already established.
        try await wait { model.firstMateFleet.selectedTarget == .init(machineID: "beta", featureID: "new") }
        await gate.open()
        await newer.value; await old.value
        #expect(model.firstMateFleet.selectedTarget == .init(machineID: "beta", featureID: "new"))
        let alphaCalls = await alpha.listCalls, betaCalls = await beta.listCalls
        #expect(alphaCalls == 0 && betaCalls == 0)
        #expect(model.selectedTab == .firstMate)
        #expect(model.toastMessage == nil)
    }

    @Test("A newer invalid app URL owns its error instead of allowing an older bootstrap to replace it")
    func invalidURLSupersedesBootstrap() async throws {
        let model = model(), gate = NavigationReviewGate()
        let sources = [source("alpha", NavigationReviewClient(ids: ["old"], listGate: gate)),
                       source("beta", NavigationReviewClient(ids: ["new"]))]
        let old = model.openFirstMate(try request("old"), sources: sources)
        defer { old.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        let invalid = try #require(URL(string: "herdr://first-mate?feature_id=old&token=forbidden"))
        model.open(url: invalid)
        let error = model.toastMessage
        #expect(error?.contains("invalid") == true)
        await gate.open(); await old.value
        #expect(model.firstMateFleet.selectedTarget == nil && model.selectedTab == .notes)
        #expect(model.toastMessage == error)
    }

    @Test("Newer app-wide navigation owns tab, pane, car and toast after old First Mate completion",
          arguments: ["bootstrap-success", "bootstrap-error", "detail-success", "detail-error"],
          ["pane-url", "pane-manual", "tab", "tab-first-mate", "car-url", "car-manual"])
    func appWideSupersession(_ scenario: String, _ destination: String) async throws {
        let model = model(), gate = NavigationReviewGate()
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "alpha") }
        let pane = try #require(model.workspaces.first?.panes.first)
        let bootstrap = scenario.hasPrefix("bootstrap"), failure = scenario.hasSuffix("error")
        let sources = [source("alpha", NavigationReviewClient(ids: ["old"], listGate: bootstrap ? gate : nil,
            detailGate: bootstrap ? nil : gate, failList: bootstrap && failure, failDetail: !bootstrap && failure)),
            source("beta", NavigationReviewClient(ids: ["new"]))]
        if !bootstrap { model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration) }
        let old = model.openFirstMate(try request("old", on: bootstrap ? nil : "alpha"), sources: sources)
        defer { old.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        switch destination {
        case "pane-url":
            let encoded = try #require(pane.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            model.open(url: try #require(URL(string: "herdr://pane/" + encoded)))
        case "pane-manual": model.openPane(id: pane.id)
        case "tab": model.selectTab(.attention)
        case "tab-first-mate": model.selectTab(.firstMate)
        case "car-url": model.open(url: try #require(URL(string: "herdr://car")))
        default: model.openCarMode()
        }
        let expectedTab = model.selectedTab
        let expectedPane = model.selectedPaneID
        let expectedWorkspace = model.selectedWorkspaceID
        let expectedPath = model.workspacePath
        let expectedCar = model.isCarModePresented
        model.toastMessage = "New navigation owns this synthetic toast"
        await gate.open(); await old.value
        #expect(model.selectedTab == expectedTab)
        #expect(model.selectedPaneID == expectedPane && model.selectedWorkspaceID == expectedWorkspace)
        #expect(model.workspacePath == expectedPath && model.isCarModePresented == expectedCar)
        #expect(model.firstMateFleet.selectedTarget == nil && model.firstMateFleet.chat.route == nil)
        #expect(model.firstMateFleet.chat.routingError == nil)
        #expect(model.toastMessage == "New navigation owns this synthetic toast")
        if destination.hasPrefix("pane") { #expect(expectedPane == pane.id && expectedTab == .workspaces) }
        if destination.hasPrefix("car") { #expect(expectedCar) }
    }

    @Test("Ordinary interaction and content refresh do not supersede a First Mate route")
    func interactionIsNotNavigation() async throws {
        let model = model(), gate = NavigationReviewGate()
        let sources = [source("alpha", NavigationReviewClient(ids: ["old"], detailGate: gate))]
        model.firstMateFleet.activate(sources: sources, connectionGeneration: model.connectionGeneration)
        let opening = model.openFirstMate(try request("old", on: "alpha"), sources: sources)
        defer { opening.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        model.noteUserInteraction(machineID: "alpha")
        model.workspaces = DemoData.workspaces.map { $0.stamped(machineID: "alpha") }
        model.isSidebarPresented = true
        await gate.open(); await opening.value
        #expect(model.selectedTab == .firstMate)
        #expect(model.firstMateFleet.selectedTarget == .init(machineID: "alpha", featureID: "old"))
    }

    @Test("Pending pane recovery retains its original intent, but never supersedes a newer First Mate route", arguments: [false, true])
    func pendingPaneRecovery(_ superseded: Bool) async throws {
        let model = model()
        let workspace = DemoData.workspaces[0].stamped(machineID: "alpha")
        let pane = try #require(workspace.panes.first)
        model.openPane(id: pane.paneID)
        #expect(model.selectedPaneID == nil)
        if superseded {
            let sources = [source("alpha", NavigationReviewClient(ids: ["new"]))]
            await model.openFirstMate(try request("new", on: "alpha"), sources: sources).value
        }
        model.noteUserInteraction()
        model.workspaces = [workspace]
        model.resolvePendingPaneRoute()
        if superseded {
            #expect(model.selectedPaneID == nil && model.selectedTab == .firstMate)
            #expect(model.firstMateFleet.selectedTarget == .init(machineID: "alpha", featureID: "new"))
        } else {
            #expect(model.selectedPaneID == pane.id && model.selectedTab == .workspaces)
            #expect(model.workspacePath == [.pane(pane.id)])
        }
    }

    @Test("Connection rotation fences a held app bootstrap and its failure", arguments: [false, true])
    func bootstrapRotation(_ changesGeneration: Bool) async throws {
        let model = model(), gate = NavigationReviewGate()
        let sources = [source("alpha", NavigationReviewClient(ids: ["old"], listGate: gate, failList: true)),
                       source("beta", NavigationReviewClient(ids: ["new"]))]
        let old = model.openFirstMate(try request("old"), sources: sources)
        defer { old.cancel(); Task { await gate.open() } }
        try await wait { await gate.arrivals > 0 }
        if changesGeneration { model.connectionGeneration += 1 }
        let replacement = [source("alpha", NavigationReviewClient(ids: ["old"]), token: "replacement"), sources[1]]
        model.firstMateFleet.activate(sources: replacement, connectionGeneration: model.connectionGeneration)
        await model.openFirstMate(try request("new", on: "beta"), sources: replacement).value
        await gate.open(); await old.value
        #expect(model.firstMateFleet.selectedTarget == .init(machineID: "beta", featureID: "new"))
        #expect(model.toastMessage == nil)
    }
}

private actor NavigationReviewGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor NavigationReviewClient: FirstMateClient {
    let ids: [String]
    let listGate: NavigationReviewGate?
    let detailGate: NavigationReviewGate?
    let failList: Bool
    let failDetail: Bool
    private(set) var listCalls = 0
    init(ids: [String], listGate: NavigationReviewGate? = nil, detailGate: NavigationReviewGate? = nil,
         failList: Bool = false, failDetail: Bool = false) {
        self.ids = ids; self.listGate = listGate; self.detailGate = detailGate
        self.failList = failList; self.failDetail = failDetail
    }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities { .init(ok: true, capabilities: ["first-mate-v1", "first-mate-fleet-v1"]) }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        listCalls += 1
        await listGate?.wait()
        if failList { throw APIError.server(status: 503, message: "Synthetic list failure") }
        return .init(ok: true, features: ids.map { ChatFixtures.feature($0, status: "blocked") })
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        .init(features: ids.map { ChatFixtures.entry($0, hud: .blocked, latestFirstMate: "reply-" + $0) })
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        await detailGate?.wait()
        if failDetail { throw APIError.server(status: 503, message: "Synthetic detail failure") }
        guard ids.contains(id) else { throw APIError.invalidResponse }
        return .init(feature: ChatFixtures.feature(id, status: "blocked"))
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
