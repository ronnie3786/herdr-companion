import Foundation
import Observation
@testable import herdr_harness_mac

enum AgentRoleTestFixtures {
    static let machines = [
        HerdrMachine(id: "desktop", name: "Desktop", urlString: "http://localhost:9092"),
        HerdrMachine(id: "laptop", name: "Laptop", urlString: "http://localhost:9093"),
    ]
    static let skills = [
        AgentRoleSkill(id: "skill_alpha", name: "Atlas notes", description: "Turn a collection of synthetic planning notes into a compact, organized outline with clear next steps.", source: "personal", path: "/example/skills/atlas/SKILL.md", estimatedTokens: 90),
        AgentRoleSkill(id: "skill_bravo", name: "Build compass", description: "Inspect a sample project's build settings and describe the relevant verification steps before making changes.", source: "project", path: "/example/project/build/SKILL.md", estimatedTokens: 110),
        AgentRoleSkill(id: "skill_charlie", name: "Change summary", description: "Write a concise summary of a sample change, including observable behavior and the checks that support it.", source: "personal", path: "/example/skills/summary/SKILL.md", estimatedTokens: 80),
    ]
    static let roles: [AgentRole] = [
        role("first_mate", "First Mate", skills: nil),
        role("second_mate", "Second Mate", skills: ["skill_alpha"]),
        role("worker", "Worker", skills: ["skill_bravo"]),
        role("planner", "Planner", skills: []),
        role("architect", "Architect", skills: []),
        role("research_scout", "Research Scout", skills: []),
        AgentRole(id: "recovery_advisor", builtin: true, locked: true, name: "Recovery Advisor",
            whenToUse: "Restricted recovery checks.", systemPrompt: "", modelProfile: "execution", allowDelegation: false, skillIds: []),
    ]

    static func role(_ id: String, _ name: String, skills: [String]?) -> AgentRole {
        AgentRole(id: id, builtin: true, locked: false, name: name, whenToUse: "",
                  systemPrompt: "", modelProfile: "execution", allowDelegation: false, skillIds: skills)
    }

    static func overview(revision: Int = 0, roles: [AgentRole] = roles, machineID: String = "server-desktop") -> AgentRolesOverview {
        AgentRolesOverview(ok: true, capability: "agent-roles-v1", machineId: machineID, revision: revision,
            roles: roles, skills: skills, sources: [], warnings: [])
    }
}

@MainActor
@Observable
final class AgentRoleTestCatalog: AgentRoleSkillCatalog {
    var sources = [
        AgentRoleSkillSource(id: "personal", name: "Personal", path: "/example/skills", available: true),
        AgentRoleSkillSource(id: "project", name: "Project", path: "/example/project", available: true),
    ]
    var skills = AgentRoleTestFixtures.skills
    var errorMessage: String?
    var isLoading = false
    var bundledIDs: Set<String> = []
    func refresh() async {}
    func addSource(_ url: URL, name: String?) throws {}
    func removeSource(_ id: String) {}
    func bundles(for ids: Set<String>) async throws -> [AgentRoleSkillBundle] {
        bundledIDs = ids
        return skills.filter { ids.contains($0.id) }.map {
            AgentRoleSkillBundle(id: $0.id, name: $0.name, description: $0.description, source: $0.source,
                files: [.init(path: "SKILL.md", content: Data("Synthetic skill".utf8).base64EncodedString(), executable: false)])
        }
    }
}

actor AgentRoleTestClient: AgentRolesClient {
    private var overview: AgentRolesOverview
    private var mutations: [AgentRoleMutation] = []
    private var failure: APIError?
    private var mutationResponse: AgentRolesOverview?
    init(overview: AgentRolesOverview = AgentRoleTestFixtures.overview()) { self.overview = overview }
    func fail(with error: APIError?) { failure = error }
    func respondToMutation(with response: AgentRolesOverview) { mutationResponse = response }
    func recordedMutations() -> [AgentRoleMutation] { mutations }
    func fetchAgentRoles() async throws -> AgentRolesOverview {
        if let failure { throw failure }
        return overview
    }
    func mutateAgentRoles(_ mutation: AgentRoleMutation) async throws -> AgentRolesOverview {
        mutations.append(mutation)
        if let failure { throw failure }
        if let mutationResponse { return mutationResponse }
        guard mutation.expectedRevision == overview.revision else {
            throw APIError.server(status: 409, message: "Changed elsewhere")
        }
        var roles = overview.roles
        if let role = mutation.role {
            if let index = roles.firstIndex(where: { $0.id == role.id }) { roles[index] = role }
            else { roles.append(role) }
        } else { roles.removeAll { $0.id == mutation.roleId } }
        overview = AgentRoleTestFixtures.overview(revision: overview.revision + 1, roles: roles, machineID: overview.machineId)
        return overview
    }
}

actor DelayedAgentRolesTestClient: AgentRolesClient {
    private var continuation: CheckedContinuation<AgentRolesOverview, any Error>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fetchAgentRoles() async throws -> AgentRolesOverview {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilRequested() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ overview: AgentRolesOverview) { continuation?.resume(returning: overview); continuation = nil }
    func mutateAgentRoles(_ mutation: AgentRoleMutation) async throws -> AgentRolesOverview { throw APIError.invalidResponse }
}
