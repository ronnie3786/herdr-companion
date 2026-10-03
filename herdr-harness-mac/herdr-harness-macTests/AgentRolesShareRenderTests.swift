import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles sharing renders", .serialized)
@MainActor
struct AgentRolesShareRenderTests {
    private typealias Fixtures = AgentRoleTestFixtures

    @Test("The export sheet groups roles and teams and notes unsaved edits")
    func exportSheet() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToSharePreview(with: try Fixtures.sharePreview())
        let (store, model) = await makeModel(client)
        store.draft?.systemPrompt = "Unsaved sample edit."
        await model.loadExportPreview()
        model.setExportRole(Fixtures.contrastID, selected: false)
        let result = try await HerdrRenderHarness.render("agent-roles-export-sheet.png", size: CGSize(width: 640, height: 600)) {
            AgentRolesExportSheet(model: model)
        }
        result.expectSubstantial()
    }

    @Test("The import sheet shows new, replaced, unchanged and skipped roles, teams and skill outcomes")
    func importSheet() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan())])
        let (_, model) = await makeModel(client)
        await model.openImport(fileName: "herdr-roles-20261002.json", data: try Fixtures.shareDocument())
        model.setImportRole("worker", selected: true)
        #expect(model.importPlan != nil)
        let result = try await HerdrRenderHarness.render("agent-roles-import-sheet.png", size: CGSize(width: 680, height: 640)) {
            AgentRolesImportSheet(model: model)
        }
        result.expectSubstantial()
    }

    @Test("Expanded import rows show prompts, changes and skill files as plain text")
    func importDetails() async throws {
        let plan = try Fixtures.samplePlan()
        let worker = try #require(plan.roles.first { $0.id == "worker" })
        let atlas = try #require(plan.roles.first { $0.id == "sample-review-agent" })
        let skill = try #require(plan.skills.first)
        let result = try await HerdrRenderHarness.render("agent-roles-import-details.png", size: CGSize(width: 680, height: 640)) {
            VStack(alignment: .leading, spacing: 10) {
                AgentRolesImportRow(role: worker, machine: "Desktop", selected: .constant(true), enabled: true, expanded: true)
                AgentRolesImportRow(role: atlas, machine: "Desktop", selected: .constant(false), enabled: true, expanded: true)
                AgentRolesImportSkillRow(skill: skill, machine: "Desktop", usedBy: ["Worker"])
                Spacer(minLength: 0)
            }
            .padding(24)
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
            .foregroundStyle(HerdrTheme.primaryText)
        }
        result.expectSubstantial()
    }

    @Test("The import sheet explains a file it can't import")
    func importRejected() async throws {
        let (_, model) = await makeModel(AgentRoleTestClient(overview: Fixtures.shareOverview()))
        await model.openImport(fileName: "herdr-roles-20261002.json", data: try Fixtures.shareDocument(version: 2))
        #expect(model.importError != nil)
        let result = try await HerdrRenderHarness.render("agent-roles-import-rejected.png", size: CGSize(width: 680, height: 640)) {
            AgentRolesImportSheet(model: model)
        }
        result.expectSubstantial()
    }

    @Test("Saved copies on the execution computer render apart from missing skills")
    func savedCopies() async throws {
        let imported = AgentRoleSkill(id: "skill_imported", name: "Sample importer", description: "Synthetic skill.",
                                      source: "agents", path: "/example/host/skills/importer/SKILL.md", estimatedTokens: 40)
        let store = AgentRolesStore(machines: Fixtures.machines,
            clients: ["desktop": AgentRoleTestClient(overview: Fixtures.shareOverview(skills: Fixtures.skills + [imported]))],
            catalog: AgentRoleTestCatalog())
        await store.load()
        store.selectRole("worker")
        store.draft?.skillIds = ["skill_bravo", "skill_imported", "skill_unknown"]
        #expect(store.savedCopyIDs == ["skill_imported"])
        let result = try await HerdrRenderHarness.render("agent-roles-saved-copies.png", size: CGSize(width: 685, height: 632)) {
            AgentRolesView(store: store, initialTab: .skills)
        }
        result.expectSubstantial()
    }

    private func makeModel(_ client: AgentRoleTestClient) async -> (AgentRolesStore, AgentRolesShareModel) {
        let store = AgentRolesStore(machines: Fixtures.machines, clients: ["desktop": client], catalog: AgentRoleTestCatalog())
        await store.load()
        return (store, AgentRolesShareModel(store: store))
    }
}
