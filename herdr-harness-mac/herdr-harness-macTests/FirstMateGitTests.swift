import Foundation
import Testing
@testable import herdr_harness_mac

struct FirstMateGitTargetTests {
    @Test("Window identity includes machine feature and workspace")
    func identity() throws {
        let project = FirstMateGitWindowTarget(machineID: "machine-a", featureID: "feature", workspaceID: "project")
        let worker = FirstMateGitWindowTarget(machineID: "machine-a", featureID: "feature", workspaceID: "worker")
        let otherMachine = FirstMateGitWindowTarget(machineID: "machine-b", featureID: "feature", workspaceID: "project")
        #expect(project != worker)
        #expect(project != otherMachine)
        #expect(Set([project.id, worker.id, otherMachine.id]).count == 3)
        #expect(try JSONDecoder().decode(FirstMateGitWindowTarget.self, from: JSONEncoder().encode(worker)) == worker)
    }

    @Test("First Mate web route escapes identity and keeps the token out of the URL")
    func webDocumentRoute() throws {
        let token = "synthetic-secret-\"token"
        let configuration = try #require(ServerConfiguration(urlString: "https://herdr.example.test/base", token: token))
        let target = FirstMateGitWindowTarget(machineID: "machine", featureID: "feature/one", workspaceID: "worker two")
        let document = PaneGitWebDocument(configuration: configuration, firstMateTarget: target)
        let components = try #require(URLComponents(url: document.url, resolvingAgainstBaseURL: false))
        var route = URLComponents()
        route.percentEncodedQuery = components.percentEncodedFragment
        let values = Dictionary(uniqueKeysWithValues: (route.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(values["firstMate"] == "feature/one")
        #expect(values["workspace"] == "worker two")
        #expect(values["pane"] == nil)
        #expect(values["view"] == "git")
        #expect(values["embed"] == "1")
        #expect(!document.url.absoluteString.contains(token))
        #expect(document.allowedOrigin == PaneGitWebOrigin(url: configuration.baseURL))
    }
}

@Suite("First Mate Git load identity")
@MainActor
struct FirstMateGitLoadIdentityTests {
    @Test("Terminal connection churn leaves Git mounted; target and credential changes still reload")
    func companionIdentityIsIndependentOfTerminal() throws {
        let defaultsName = "FirstMateGitLoadIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = HerdrAppModel(
            credentials: TestCredentialStore(), arguments: ["test"],
            userDefaults: defaults, configuredMachines: []
        )
        let configuration = try #require(ServerConfiguration(
            urlString: "https://companion.example.test", token: "synthetic-token"
        ))
        let rotatedConfiguration = try #require(ServerConfiguration(
            urlString: "https://companion.example.test", token: "synthetic-new-token"
        ))
        func identity(
            machine: String = "machine-a",
            feature: String = "feature",
            revision: Int = 1,
            retry: Int = 0,
            missingConfiguration: Bool = false,
            rotatedCredentials: Bool = false
        ) -> FirstMateGitLoadIdentity {
            let view = FirstMateGitView(
                model: model, machineID: machine, featureID: feature,
                featureTitle: "Synthetic feature",
                configuration: missingConfiguration ? nil : (rotatedCredentials ? rotatedConfiguration : configuration),
                configurationRevision: revision
            )
            // retryGeneration is view-local; changing its identity explicitly
            // below covers the Refresh action without relying on a timer.
            let current = view.loadIdentity
            return FirstMateGitLoadIdentity(
                machineID: current.machineID, featureID: current.featureID,
                configurationRevision: current.configurationRevision,
                url: current.url, token: current.token, retryGeneration: retry
            )
        }
        model.machineStates["machine-a"] = .connecting
        let before = identity()
        model.machineStates["machine-a"] = .live
        #expect(identity() == before)
        model.machineStates["machine-a"] = .failed
        #expect(identity() == before)
        #expect(identity(machine: "machine-b") != before)
        #expect(identity(feature: "other-feature") != before)
        #expect(identity(revision: 2) != before)
        #expect(identity(retry: 1) != before)
        #expect(identity(missingConfiguration: true) != before)
        #expect(identity(rotatedCredentials: true) != before)
    }
}

@Suite("First Mate workspace observation identity")
@MainActor
struct FirstMateWorkspaceObservationIDTests {
    @Test("The same store and selected feature produce a stable identity")
    func sameStoreAndFeatureIsStable() {
        let store = FirstMateStore()
        store.selectedFeatureID = "feature"

        #expect(FirstMateWorkspaceObservationID(store: store) == FirstMateWorkspaceObservationID(store: store))
    }

    @Test("A recreated store changes identity even when the selected feature matches")
    func recreatedStoreChangesIdentity() {
        let original = FirstMateStore()
        original.selectedFeatureID = "feature"
        let replacement = FirstMateStore()
        replacement.selectedFeatureID = "feature"

        #expect(FirstMateWorkspaceObservationID(store: original) != FirstMateWorkspaceObservationID(store: replacement))
    }

    @Test("Changing selection changes the same store's identity")
    func changedSelectionChangesIdentity() {
        let store = FirstMateStore()
        store.selectedFeatureID = "feature-a"
        let original = FirstMateWorkspaceObservationID(store: store)

        store.selectedFeatureID = "feature-b"

        #expect(original != FirstMateWorkspaceObservationID(store: store))
    }
}

private actor FirstMateGitClientFixture: FirstMateGitClient {
    let capabilities: [String]
    let capabilityError: APIError?
    let workspaceError: APIError?
    let blockedFeatureID: String?
    let blockedRequestNumber: Int
    var workspacesByFeature: [String: [FirstMateGitWorkspace]]
    let titlesByFeature: [String: String]

    private(set) var capabilityRequestCount = 0
    private(set) var workspaceRequestIDs: [String] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        capabilities: [String] = ["first-mate-git-v1"],
        capabilityError: APIError? = nil,
        workspaceError: APIError? = nil,
        workspacesByFeature: [String: [FirstMateGitWorkspace]],
        titlesByFeature: [String: String],
        blockedFeatureID: String? = nil,
        blockedRequestNumber: Int = 1
    ) {
        self.capabilities = capabilities
        self.capabilityError = capabilityError
        self.workspaceError = workspaceError
        self.workspacesByFeature = workspacesByFeature
        self.titlesByFeature = titlesByFeature
        self.blockedFeatureID = blockedFeatureID
        self.blockedRequestNumber = blockedRequestNumber
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        capabilityRequestCount += 1
        if let capabilityError { throw capabilityError }
        return .init(ok: true, capabilities: capabilities)
    }

    func fetchFirstMateGitWorkspaces(featureID: String) async throws -> FirstMateGitWorkspaceResponse {
        workspaceRequestIDs.append(featureID)
        if let workspaceError { throw workspaceError }
        if featureID == blockedFeatureID &&
            workspaceRequestIDs.filter({ $0 == featureID }).count == blockedRequestNumber {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return .init(ok: true, workspaces: workspacesByFeature[featureID] ?? [])
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        FirstMateSnapshot(feature: .init(
            id: id,
            title: titlesByFeature[id] ?? "Synthetic feature",
            goal: "Synthetic goal",
            cwd: "/synthetic/\(id)",
            status: "ready",
            currentVisitID: nil,
            revision: 1,
            createdAt: "2026-09-22T00:00:00Z",
            updatedAt: "2026-09-22T00:00:00Z",
            workItemID: nil
        ))
    }

    func setWorkspaces(_ workspaces: [FirstMateGitWorkspace], featureID: String) {
        workspacesByFeature[featureID] = workspaces
    }

    func waitUntilBlockedWorkspaceRequest() async {
        guard blockedContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedWorkspaceRequest() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func workspaceRequestCount() -> Int { workspaceRequestIDs.count }
}

@Suite("First Mate Git catalog", .timeLimit(.minutes(1)))
@MainActor
struct FirstMateGitCatalogTests {
    private let project = FirstMateGitWorkspace(
        id: "project",
        title: "Project workspace",
        path: "/synthetic/project"
    )
    private let worker = FirstMateGitWorkspace(
        id: "worker",
        title: "Implementation worker",
        path: "/synthetic/worker"
    )

    @Test("Same-target refresh preserves a worker and a logical target change resets to project")
    func selectionLifecycle() async {
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["feature": [project, worker]],
            titlesByFeature: ["feature": "Synthetic feature"]
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(machineID: "machine-a", featureID: "feature", client: fixture, demo: false)
        catalog.selectWorkspace(id: "worker")
        await catalog.load(machineID: "machine-a", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.selectedWorkspaceID == "worker")
        #expect(catalog.selectedWorkspace?.path == "/synthetic/worker")

        await fixture.setWorkspaces([project], featureID: "feature")
        await catalog.load(machineID: "machine-a", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.selectedWorkspaceID == "worker")
        #expect(catalog.selectedWorkspace == nil)

        await catalog.load(machineID: "machine-b", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.selectedWorkspaceID == "project")
    }

    @Test("A same-target refresh leaves the existing Git workbench mounted")
    func refreshPreservesReadyContent() async {
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["feature": [project, worker]],
            titlesByFeature: ["feature": "Synthetic feature"],
            blockedFeatureID: "feature", blockedRequestNumber: 2
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(machineID: "machine", featureID: "feature", client: fixture, demo: false)
        catalog.selectWorkspace(id: "worker")
        let refresh = Task {
            await catalog.load(machineID: "machine", featureID: "feature", client: fixture, demo: false)
        }
        await fixture.waitUntilBlockedWorkspaceRequest()
        #expect(catalog.phase == .ready)
        #expect(catalog.featureTitle == "Synthetic feature")
        #expect(catalog.selectedWorkspace == worker)
        await fixture.releaseBlockedWorkspaceRequest()
        await refresh.value
        #expect(catalog.phase == .ready)
        #expect(catalog.selectedWorkspace == worker)
    }

    @Test("Changing the companion configuration hides old-host content while retaining the exact selection")
    func connectionChangeClearsOldContent() async throws {
        let original = try #require(ServerConfiguration(
            urlString: "https://old.example.test", token: "synthetic-old-token"
        ))
        let replacement = try #require(ServerConfiguration(
            urlString: "https://new.example.test", token: "synthetic-new-token"
        ))
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["feature": [project, worker]],
            titlesByFeature: ["feature": "Synthetic feature"],
            blockedFeatureID: "feature", blockedRequestNumber: 2
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(
            machineID: "machine", featureID: "feature", client: fixture, demo: false,
            configuration: original, configurationRevision: 1
        )
        catalog.selectWorkspace(id: "worker")
        let reconnect = Task {
            await catalog.load(
                machineID: "machine", featureID: "feature", client: fixture, demo: false,
                configuration: replacement, configurationRevision: 2
            )
        }
        await fixture.waitUntilBlockedWorkspaceRequest()
        #expect(catalog.phase == .loading)
        #expect(catalog.featureTitle == nil)
        #expect(catalog.workspaces.isEmpty)
        #expect(catalog.selectedWorkspaceID == "worker")
        await fixture.releaseBlockedWorkspaceRequest()
        await reconnect.value
        #expect(catalog.phase == .ready)
        #expect(catalog.selectedWorkspace == worker)
        #expect(catalog.identity == .init(
            machineID: "machine", featureID: "feature",
            configuration: replacement, configurationRevision: 2
        ))
    }

    @Test("A recreated same-feature Git view restores its explicit worker selection")
    func restoredSelection() async {
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["feature": [project, worker]],
            titlesByFeature: ["feature": "Synthetic feature"]
        )
        let catalog = FirstMateGitCatalog(initialWorkspaceID: "worker")
        await catalog.load(machineID: "machine", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.selectedWorkspaceID == "worker")
        #expect(catalog.selectedWorkspace?.path == "/synthetic/worker")
    }

    @Test("Pinned catalogs select exactly one workspace and never permit picker retargeting or fallback")
    func pinnedSelection() async {
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["feature": [project]],
            titlesByFeature: ["feature": "Pinned feature"]
        )
        let catalog = FirstMateGitCatalog(pinnedWorkspaceID: "removed-worker")
        await catalog.load(machineID: "machine", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.isPinned)
        #expect(catalog.selectedWorkspaceID == "removed-worker")
        #expect(catalog.selectedWorkspace == nil)
        catalog.selectWorkspace(id: "project")
        #expect(catalog.selectedWorkspaceID == "removed-worker")
    }

    @Test("Capability gate prevents every new endpoint call on an older server")
    func unsupportedDoesNotRequestCatalog() async {
        let fixture = FirstMateGitClientFixture(
            capabilities: ["first-mate-v1"],
            workspaceError: .invalidResponse,
            workspacesByFeature: ["feature": [project]],
            titlesByFeature: ["feature": "Old server"]
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(machineID: "machine", featureID: "feature", client: fixture, demo: false)
        #expect(catalog.phase == .unsupported)
        let requests = await fixture.workspaceRequestCount()
        #expect(requests == 0)
    }

    @Test("Capability 404 means upgrade required while authentication failures remain failures")
    func capabilityFailures() async {
        let missingEndpoint = FirstMateGitClientFixture(
            capabilityError: .server(status: 404, message: "not found"),
            workspacesByFeature: [:],
            titlesByFeature: [:]
        )
        let oldCatalog = FirstMateGitCatalog()
        await oldCatalog.load(machineID: "machine", featureID: "feature", client: missingEndpoint, demo: false)
        #expect(oldCatalog.phase == .unsupported)
        let missingEndpointRequests = await missingEndpoint.workspaceRequestCount()
        #expect(missingEndpointRequests == 0)

        let unauthorized = FirstMateGitClientFixture(
            capabilityError: .server(status: 401, message: "Unauthorized"),
            workspacesByFeature: [:],
            titlesByFeature: [:]
        )
        let unauthorizedCatalog = FirstMateGitCatalog()
        await unauthorizedCatalog.load(machineID: "machine", featureID: "feature", client: unauthorized, demo: false)
        #expect(unauthorizedCatalog.phase == .failed("Unauthorized"))
        let unauthorizedRequests = await unauthorized.workspaceRequestCount()
        #expect(unauthorizedRequests == 0)

        let transportFailure = FirstMateGitClientFixture(
            capabilityError: .invalidResponse,
            workspacesByFeature: [:],
            titlesByFeature: [:]
        )
        let failedCatalog = FirstMateGitCatalog()
        await failedCatalog.load(machineID: "machine", featureID: "feature", client: transportFailure, demo: false)
        #expect(failedCatalog.phase == .failed("The Herdr server returned an invalid response."))
    }

    @Test("Feature switches clear the prior title and path before the new response arrives")
    func featureSwitchClearsTransientContent() async {
        let oldWorkspace = FirstMateGitWorkspace(id: "project", title: "Old project", path: "/old/path")
        let newWorkspace = FirstMateGitWorkspace(id: "project", title: "New project", path: "/new/path")
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["old": [oldWorkspace], "new": [newWorkspace]],
            titlesByFeature: ["old": "Old title", "new": "New title"],
            blockedFeatureID: "new"
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(machineID: "machine", featureID: "old", client: fixture, demo: false)
        let switched = Task {
            await catalog.load(machineID: "machine", featureID: "new", client: fixture, demo: false)
        }
        await fixture.waitUntilBlockedWorkspaceRequest()
        #expect(catalog.phase == .loading)
        #expect(catalog.featureTitle == nil)
        #expect(catalog.workspaces.isEmpty)
        #expect(catalog.selectedWorkspace == nil)
        await fixture.releaseBlockedWorkspaceRequest()
        await switched.value
        #expect(catalog.featureTitle == "New title")
        #expect(catalog.selectedWorkspace?.path == "/new/path")
    }

    @Test("A delayed response cannot repopulate title or path after reset and reload")
    func staleResponseAfterReset() async {
        let oldWorkspace = FirstMateGitWorkspace(id: "project", title: "Old project", path: "/old/path")
        let newWorkspace = FirstMateGitWorkspace(id: "project", title: "New project", path: "/new/path")
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: ["old": [oldWorkspace], "new": [newWorkspace]],
            titlesByFeature: ["old": "Old title", "new": "New title"],
            blockedFeatureID: "old"
        )
        let catalog = FirstMateGitCatalog()
        let stale = Task {
            await catalog.load(machineID: "machine", featureID: "old", client: fixture, demo: false)
        }
        await fixture.waitUntilBlockedWorkspaceRequest()
        catalog.reset()
        await catalog.load(machineID: "machine", featureID: "new", client: fixture, demo: false)
        await fixture.releaseBlockedWorkspaceRequest()
        await stale.value

        #expect(catalog.identity == .init(machineID: "machine", featureID: "new"))
        #expect(catalog.featureTitle == "New title")
        #expect(catalog.selectedWorkspace?.path == "/new/path")
        #expect(!catalog.workspaces.contains { $0.path == "/old/path" })
    }

    @Test("Demo catalog is deterministic, makes no client request, and native paths match selection")
    func demoCatalog() async throws {
        let fixture = FirstMateGitClientFixture(
            workspacesByFeature: [:],
            titlesByFeature: [:]
        )
        let catalog = FirstMateGitCatalog()
        await catalog.load(machineID: "demo", featureID: "demo-feature", client: fixture, demo: true)
        catalog.selectWorkspace(id: "demo-worker")
        let selected = try #require(catalog.selectedWorkspace)
        #expect(selected.path == "/demo/worktrees/implementation")
        #expect(FirstMateGitDemo.nativeWorkspace(for: selected).displayPath == selected.path)
        let requests = await fixture.workspaceRequestCount()
        #expect(requests == 0)
    }
}
