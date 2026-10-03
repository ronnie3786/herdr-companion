import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review host scope shell", .serialized, .timeLimit(.minutes(1)))
struct PRReviewHostScopeShellTests {
    @Test("A fresh shell starts in All machines, independently of the detail host")
    func startsInAllMachines() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == nil)
        #expect(fixture.shell.prReviewFleet.sourceCount == 0)
        #expect(WorkspaceNavigationView.prReviewHostTitle(scope: fixture.shell.prReviewScope, machines: fixture.model.machines) == "All machines")
    }

    @Test("The host title uses the scope, not the open review's machine")
    func hostTitles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.prReviewMachineID = "host-b"
        #expect(WorkspaceNavigationView.prReviewHostTitle(scope: .all, machines: fixture.model.machines) == "All machines")
        #expect(WorkspaceNavigationView.prReviewHostTitle(scope: .machine("host-b"), machines: fixture.model.machines) == "Beta Forge")
        #expect(WorkspaceNavigationView.prReviewHostTitle(scope: .machine("removed"), machines: fixture.model.machines) == "Choose a host")
    }

    @Test("Choosing a machine routes the detail host; All machines retains that owner")
    func explicitHostSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        #expect(fixture.shell.prReviewScope == .machine("host-b"))
        #expect(fixture.shell.prReviewMachineID == "host-b")
        fixture.shell.selectPRReviewScope(.all)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @Test("Re-entering PR Review defaults to All machines without clearing its detail owner")
    func reentryResetsScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.show(.prReview, model: fixture.model)
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        fixture.shell.show(.prReview, model: fixture.model)
        #expect(fixture.shell.prReviewScope == .machine("host-b"))
        fixture.shell.show(.home, model: fixture.model)
        fixture.shell.show(.prReview, model: fixture.model)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @Test("Back and Forward into PR Review also reset its host scope")
    func historyReentryResetsScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.show(.home, model: fixture.model)
        fixture.shell.show(.prReview, model: fixture.model)
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        #expect(fixture.shell.goBack(model: fixture.model))
        #expect(fixture.shell.detailScope == .home)
        #expect(fixture.shell.goForward(model: fixture.model))
        #expect(fixture.shell.detailScope == .prReview)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @Test("An exact review open uses All machines and preserves the existing request route")
    func exactReviewOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.show(.prReview, model: fixture.model)
        fixture.shell.selectPRReviewScope(.machine("host-a"))
        fixture.shell.showPRReview(machineID: "host-b", reviewID: "prr_shared", file: "Sources/Seed.swift", line: 12, model: fixture.model)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
        #expect(fixture.shell.detailScope == .prReview)
        let request = try #require(fixture.shell.prReviewOpenRequest)
        #expect(request.reviewID == "prr_shared")
        #expect(request.serverURL == "https://host-b.example.invalid")
        #expect(request.file == "Sources/Seed.swift")
        #expect(request.line == 12)
    }

    @Test("A fleet row on another machine routes its exact owner even for a duplicate ID")
    func fleetOpenOnAnotherMachine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.prReview.configure(client: nil, machineID: "host-a", demo: false)
        fixture.shell.prReview.select("prr_shared")
        fixture.shell.prReviewMachineID = "host-a"
        fixture.shell.openPRReviewFromFleet(.init(machineID: "host-b", reviewID: "prr_shared"), model: fixture.model)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
        #expect(fixture.shell.prReview.currentMachineID == "host-a") // The connection task applies the request.
        let request = try #require(fixture.shell.prReviewOpenRequest)
        #expect(request.reviewID == "prr_shared")
        #expect(request.serverURL == "https://host-b.example.invalid")
    }

    @Test("A fleet row on the configured machine selects directly and supersedes pending navigation")
    func fleetOpenOnSameMachine() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = SyntheticPRReviewGate()
        let client = SyntheticPRReviewWindowClient(reviewGate: gate)
        fixture.shell.prReview.configure(client: client, machineID: "host-b", demo: false)
        fixture.shell.showPRReview(machineID: "host-a", reviewID: "prr_old", model: fixture.model)
        fixture.shell.openPRReviewFromFleet(.init(machineID: "host-b", reviewID: "prr_selected"), model: fixture.model)
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == "host-b")
        #expect(fixture.shell.prReview.currentMachineID == "host-b")
        #expect(fixture.shell.prReview.selectedReviewID == "prr_selected")
        #expect(fixture.shell.prReviewOpenRequest == nil)
        await gate.waitUntilWaiting()
        #expect(await client.reviewIDs == ["prr_selected"])
        await gate.release()
    }

    @Test("An explicit picker choice cancels an unapplied exact-review request")
    func pickerSupersedesRequest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.showPRReview(machineID: "host-a", reviewID: "prr_old", model: fixture.model)
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        #expect(fixture.shell.prReviewOpenRequest == nil)
        #expect(fixture.shell.prReviewMachineID == "host-b")
        #expect(fixture.shell.prReviewScope == .machine("host-b"))
    }

    @Test("Creation from All machines uses the configured review host, including a Settings override")
    func creationUsesSettingsHost() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.model.prReviewMachine?.id == "host-a")
        fixture.shell.prReviewMachineID = "host-b"
        fixture.shell.preparePRReviewCreation(model: fixture.model)
        #expect(fixture.shell.prReviewMachineID == "host-a")
        #expect(fixture.shell.prReviewScope == .all)
        fixture.model.setPRReviewMachineOverride("host-b")
        fixture.shell.preparePRReviewCreation(model: fixture.model)
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @Test("Creation on a specifically selected host never switches to the Settings host")
    func singleHostCreationKeepsOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        fixture.shell.preparePRReviewCreation(model: fixture.model)
        #expect(fixture.shell.prReviewMachineID == "host-b")
        #expect(fixture.shell.prReviewScope == .machine("host-b"))
    }

    @Test("Without a Settings review host, creation keeps the open review's machine instead of guessing")
    func creationFallsBackToOpenOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.setPRReviewMachineOverride("removed")
        fixture.shell.preparePRReviewCreation(model: fixture.model)
        #expect(fixture.shell.prReviewMachineID == nil)
        fixture.shell.prReviewMachineID = "host-b"
        fixture.shell.preparePRReviewCreation(model: fixture.model)
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @Test("The Settings revision reset handler restores All machines and clears stale routes")
    func settingsReset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.showPRReview(machineID: "host-b", reviewID: "prr_old", model: fixture.model)
        fixture.shell.prReviewScope = .machine("host-b")
        #expect(fixture.shell.prReviewOpenRequest != nil)
        let revision = fixture.model.prReviewMachineRevision
        fixture.model.setPRReviewMachineOverride("host-a")
        #expect(fixture.model.prReviewMachineRevision == revision + 1)
        fixture.shell.prReviewHostSettingsDidChange()
        #expect(fixture.shell.prReviewScope == .all)
        #expect(fixture.shell.prReviewMachineID == nil)
        #expect(fixture.shell.prReviewOpenRequest == nil)
    }

    @Test("A removed machine resolves to All machines without retargeting the open review")
    func removedHostFallsBackToAll() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.shell.selectPRReviewScope(.machine("host-b"))
        fixture.model.machines.removeAll { $0.id == "host-b" }
        let scope = PRReviewHostScope.resolved(fixture.shell.prReviewScope, availableMachineIDs: fixture.model.machines.map(\.id))
        #expect(scope == .all)
        #expect(WorkspaceNavigationView.prReviewHostTitle(scope: scope, machines: fixture.model.machines) == "All machines")
        #expect(fixture.shell.prReviewMachineID == "host-b")
    }

    @MainActor
    private struct Fixture {
        let domain: String
        let defaults: UserDefaults
        let model: HerdrAppModel
        let shell: HerdrShellState

        init() throws {
            domain = "PRReviewHostScopeShellTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: domain))
            let credentials = TestCredentialStore()
            credentials.values["api-token.host-a"] = "synthetic-alpha-token"
            credentials.values["api-token.host-b"] = "synthetic-beta-token"
            model = HerdrAppModel(credentials: credentials, arguments: ["HerdrTests"], userDefaults: defaults, configuredMachines: [])
            model.machines = [
                HerdrMachine(id: "host-a", name: "Alpha Studio", urlString: "https://host-a.example.invalid", role: "development"),
                HerdrMachine(id: "host-b", name: "Beta Forge", urlString: "https://host-b.example.invalid"),
            ]
            shell = HerdrShellState(userDefaults: defaults)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: domain) }
    }
}
