import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR review teams")
@MainActor
struct AgentRolesTeamsTests {
    @Test("A new team is saved by ID, joined by the draft, and the draft still saves")
    func createTeamKeepsDraftSavable() async throws {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.teamsOverview())
        let store = makeStore(client)
        await store.load()
        #expect(store.supportsTeams)
        #expect(store.teams == [AgentRoleTestFixtures.sampleTeam])
        store.newPRReviewRole()
        #expect(store.draft?.teamId == "")
        store.draft?.name = "Beacon"
        #expect(store.teamNameProblem(" sample TEAM ") != nil)
        #expect(await store.createTeam(named: "  Another team "))
        let created = try #require(store.teams.first { $0.name == "Another team" })
        #expect(store.draftTeamID == created.id)
        #expect(store.draft?.group == "Another team")
        #expect(store.hasUnsavedChanges)
        await store.save()
        let mutations = await client.recordedMutations()
        #expect(mutations.map(\.action) == ["saveTeam", "save"])
        #expect(mutations[0].team == created)
        #expect(mutations[1].expectedRevision == 1)
        #expect(mutations[1].role?.teamId == created.id)
        #expect(!store.hasUnsavedChanges)
        #expect(store.errorMessage == nil)
    }

    @Test("Renaming keeps membership; deleting removes the team from agents and drafts")
    func renameAndDelete() async throws {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.teamsOverview())
        let store = makeStore(client)
        await store.load()
        store.selectRole("sample-review-agent")
        let team = AgentRoleTestFixtures.sampleTeam
        #expect(store.memberCount(ofTeam: team.id) == 1)
        #expect(await store.renameTeam(team.id, to: "Renamed team"))
        #expect(store.draft?.teamId == team.id)
        #expect(store.draft?.group == "Renamed team")
        #expect(!store.hasUnsavedChanges)
        // An unsaved edit survives a team deletion, which only clears the team.
        store.draft?.reviewPrompt = "Unsaved instructions"
        #expect(await store.deleteTeam(team.id))
        #expect(store.teams.isEmpty)
        #expect(store.draftTeamID.isEmpty)
        #expect(store.draft?.reviewPrompt == "Unsaved instructions")
        #expect(store.validationMessage == nil)
        await store.save()
        #expect(await client.recordedMutations().last?.expectedRevision == 2)
        #expect(store.savedMessage != nil)
    }

    @Test("A team deleted elsewhere blocks the save until another team is chosen")
    func missingTeamValidation() async {
        let store = makeStore(AgentRoleTestClient(overview: AgentRoleTestFixtures.teamsOverview(teams: [])))
        await store.load()
        store.selectRole("sample-review-agent")
        store.draft?.reviewPrompt = "Edited"
        #expect(store.validationMessage?.contains("team was deleted") == true)
        store.assignTeam("")
        #expect(store.validationMessage == nil)
    }

    @Test("Older companions offer the team names already in use and keep the legacy wire shape")
    func legacyCompanion() async throws {
        let client = AgentRoleTestClient(overview: AgentRoleTestFixtures.reviewOverview())
        let store = makeStore(client)
        await store.load()
        #expect(!store.supportsTeams)
        #expect(store.teams.map(\.name) == ["Sample team"])
        store.newPRReviewRole()
        #expect(store.draft?.teamId == nil)
        store.draft?.name = "Beacon"
        #expect(await store.createTeam(named: "Another team"))
        #expect(store.teams.map(\.name) == ["Another team", "Sample team"])
        let renamed = await store.renameTeam("Sample team", to: "Renamed")
        #expect(!renamed)
        await store.save()
        let mutation = try #require(await client.recordedMutations().last)
        #expect(mutation.action == "save")
        #expect(mutation.role?.group == "Another team")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation.role)) as? [String: Any]
        #expect(encoded?["teamId"] == nil)
        #expect(encoded?["group"] as? String == "Another team")
    }

    @Test("Starting a review groups agents by team ID, never by a shared name")
    func selectionGroupsByID() {
        func agent(_ id: String, team: String?, name: String) -> AgentRole {
            AgentRole(id: id, builtin: false, locked: false, name: id, whenToUse: "", systemPrompt: "",
                      modelProfile: "default", allowDelegation: false, skillIds: [], purpose: "pr_review",
                      group: name, teamId: team)
        }
        let groups = PRReviewAgentSelection.groups([
            agent("pr-review-comprehensive", team: "", name: ""),
            agent("atlas", team: "team-one", name: "Sample team"),
            agent("beacon", team: "team-two", name: "Sample team"),
            agent("compass", team: "team-one", name: "Sample team"),
            agent("delta", team: nil, name: "Legacy team"),
        ])
        #expect(groups.map(\.name) == ["", "Legacy team", "Sample team", "Sample team"])
        #expect(groups.map { $0.agents.map(\.id) } == [["pr-review-comprehensive"], ["delta"], ["atlas", "compass"], ["beacon"]])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    private func makeStore(_ client: any AgentRolesClient) -> AgentRolesStore {
        AgentRolesStore(machines: AgentRoleTestFixtures.machines, clients: ["desktop": client],
            catalog: AgentRoleTestCatalog())
    }
}
