import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate project navigation and editing")
@MainActor
struct FirstMateProjectIntegrationTests {
    @Test("The production shell routes to the new session page with project navigation")
    func shellRender() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.configureFirstMateIfNeeded(machineID: "demo", configuration: nil, connectionGeneration: model.connectionGeneration, isDemo: true)
        shell.firstMate.isDark = true
        shell.firstMateProjects.activate(sources: [], demo: true)
        await shell.firstMateProjects.refresh()
        shell.show(.firstMate, model: model)
        shell.showFirstMateStart(project: .init(machineID: "demo", projectID: "demo-ios"))
        shell.firstMateStart.prompt = "Start with SYNTH-42. Review the search behavior and propose a focused plan."
        let render = try await HerdrRenderHarness.render("first-mate-project-shell-dark.png", size: CGSize(width: 1240, height: 820)) {
            MonoRenderFixtures.window(model: model, shell: shell)
        }
        render.expectSubstantial()
        #expect(shell.firstMateSurface == .newSession)
        #expect(shell.firstMateStart.selectedProject?.projectID == "demo-ios")
    }

    @Test("Project forms keep the prompt while navigation opens the created session on its owner")
    func navigationAndStart() async throws {
        let shell = makeShell()
        shell.firstMateProjects.activate(sources: [], demo: true)
        await shell.firstMateProjects.refresh()
        let choice = try #require(shell.firstMateProjects.activeChoices.first)
        shell.firstMateStart.prompt = "  Start with SYNTH-42.\nKeep this direction intact.  "
        shell.showFirstMateStart(project: choice.id)
        shell.showFirstMateProjects()
        #expect(shell.firstMateStart.prompt.hasPrefix("  Start"))
        shell.showFirstMateStart()
        #expect(shell.firstMateStart.selectedProject == choice.id)
        let session = try #require(await shell.firstMateStart.start(in: shell.firstMateProjects))
        #expect(shell.openStartedFirstMateSession(session, connectionGeneration: 1, isDemo: true))
        #expect(shell.firstMateSurface == .workspace)
        #expect(shell.activeFirstMateMachineID == "demo")
        #expect(shell.firstMate.selectedFeatureID == session.snapshot.feature.id)
        #expect(shell.firstMate.snapshot?.feature.projectID == choice.project.id)
        #expect(shell.firstMate.snapshot?.feature.cwd == choice.project.cwd)
        #expect(shell.firstMate.snapshot?.feature.goal == "  Start with SYNTH-42.\nKeep this direction intact.  ")
        #expect(shell.firstMateStart.prompt.isEmpty)
        shell.showFirstMateStart(mode: .manual)
        #expect(shell.firstMateStart.mode == .manual)
    }

    @Test("A stale creation callback cannot navigate after leaving its connection")
    func staleNavigation() async throws {
        let shell = makeShell()
        shell.firstMateProjects.activate(sources: [], demo: true)
        await shell.firstMateProjects.refresh()
        let choice = try #require(shell.firstMateProjects.activeChoices.first)
        shell.showFirstMateStart(project: choice.id)
        shell.firstMateStart.prompt = "Investigate the synthetic app"
        let session = try #require(await shell.firstMateStart.start(in: shell.firstMateProjects))
        shell.firstMateProjects.activate(sources: [], demo: false)
        #expect(!shell.openStartedFirstMateSession(session, connectionGeneration: 2, isDemo: false))
        #expect(shell.firstMate.selectedFeatureID != session.snapshot.feature.id)
    }

    @Test("Saving, retargeting and archiving a project preserve an existing session's folder")
    func projectLifecycle() async throws {
        let index = FirstMateProjectIndex()
        index.activate(sources: [], demo: true)
        await index.refresh()
        let editor = FirstMateProjectEditorModel(preferredMachineID: "demo")
        editor.name = String(repeating: "A", count: 120)
        editor.cwd = FirstMateProjectsDemoClient.home + "/Projects/ios-app"
        #expect(editor.canSave(in: index))
        let selection = try #require(await editor.save(in: index))
        let saved = try #require(index.choice(selection))
        let start = FirstMateStartSessionModel()
        start.chooseProject(selection)
        start.prompt = "Review the existing app"
        let session = try #require(await start.start(in: index))
        let edit = FirstMateProjectEditorModel(choice: saved, connection: index.connection(for: "demo"))
        edit.cwd = FirstMateProjectsDemoClient.home + "/Projects/web-app"
        _ = try #require(await edit.save(in: index))
        let updated = try #require(index.choice(selection))
        #expect(updated.project.revision == 2)
        #expect(session.snapshot.feature.cwd == saved.project.cwd)
        #expect(session.snapshot.feature.projectRevision == 1)
        let archive = FirstMateProjectEditorModel(choice: updated, connection: index.connection(for: "demo"))
        _ = try #require(await archive.setArchived(true, in: index))
        #expect(index.choice(selection)?.project.isArchived == true)
        #expect(!index.activeChoices.contains { $0.id == selection })
        #expect(session.snapshot.feature.cwd == saved.project.cwd)
        let archived = try #require(index.choice(selection))
        let restore = FirstMateProjectEditorModel(choice: archived, connection: index.connection(for: "demo"))
        _ = try #require(await restore.setArchived(false, in: index))
        #expect(index.choice(selection)?.project.isArchived == false)
    }

    @Test("A failed conflict reload retains editable fields and blocks a stale overwrite")
    func conflictReloadFailure() async throws {
        let client = ProjectEditorTestClient()
        let machine = HerdrMachine(id: "synthetic", name: "Synthetic Mac", urlString: "https://companion.example.invalid")
        let source = FirstMateFleetSource(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic-token")!, client: client)
        let index = FirstMateProjectIndex()
        index.activate(sources: [source])
        await index.refresh()
        let choice = try #require(index.activeChoices.first)
        let editor = FirstMateProjectEditorModel(choice: choice, connection: index.connection(for: machine.id))
        editor.name = "My unsaved change"
        #expect(await editor.save(in: index) == nil)
        #expect(editor.isConflict)
        await client.setOffline(true)
        await editor.reload(in: index)
        #expect(editor.isConflict)
        #expect(editor.name == "My unsaved change")
        #expect(editor.error?.contains("Could not reload") == true)
        await client.setOffline(false)
        await editor.reload(in: index)
        #expect(!editor.isConflict)
        #expect(editor.name == "Current project")
    }

    private func makeShell() -> HerdrShellState {
        HerdrShellState(userDefaults: UserDefaults(suiteName: "FirstMateProjectIntegrationTests.\(UUID().uuidString)")!)
    }
}

private actor ProjectEditorTestClient: FirstMateClient {
    private var offline = false
    func setOffline(_ value: Bool) { offline = value }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        if offline { throw URLError(.notConnectedToInternet) }
        return .init(ok: true, capabilities: ["first-mate-projects-v1"], serverID: "synthetic-server")
    }
    func fetchFirstMateProjects(scope: FirstMateFeatureScope) async throws -> FirstMateProjectList {
        .init(ok: true, serverID: "synthetic-server", projects: [
            .init(id: "project", name: "Current project", cwd: "/srv/app", revision: 1, createdAt: "", updatedAt: "")
        ])
    }
    func updateFirstMateProject(id: String, name: String, cwd: String, expectedRevision: Int, requestID: String) async throws -> FirstMateProjectResponse {
        throw APIError.server(status: 409, message: "Project changed")
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { throw APIError.invalidResponse }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
