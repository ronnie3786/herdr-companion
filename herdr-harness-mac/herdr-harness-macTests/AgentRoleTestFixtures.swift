import Foundation
import Observation
@testable import herdr_harness_mac

enum AgentRoleTestFixtures {
    @MainActor
    static func settingsStore() -> AgentRolesStore {
        AgentRolesStore(machines: machines, clients: ["desktop": AgentRoleTestClient()], catalog: AgentRoleTestCatalog())
    }

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

    static let reviewRoles = [
        AgentRole(id: "pr-review-comprehensive", builtin: true, locked: false, name: "Comprehensive",
            whenToUse: "", systemPrompt: "", modelProfile: "default", allowDelegation: false,
            skillIds: [], purpose: "pr_review"),
        AgentRole(id: "sample-review-agent", builtin: false, locked: false, name: "Atlas",
            whenToUse: "", systemPrompt: "", modelProfile: "default", allowDelegation: false,
            skillIds: ["skill_alpha"], purpose: "pr_review", reviewPrompt: "Review the sample change for actionable regressions.\n\nPull request: {url}",
            group: "Sample team", avatar: "quality"),
    ]

    static func reviewOverview(machineID: String = "server-desktop") -> AgentRolesOverview {
        overview(roles: roles + reviewRoles, machineID: machineID, capabilities: ["pr-review-agents-v1"])
    }

    static let sampleTeam = AgentRoleTeam(id: "4f7a6c2e-1b9d-4e3a-8c55-2d6b9e0f1a11", name: "Sample team")

    /// A companion with saved teams returns a team ID on every role.
    static func teamsOverview(revision: Int = 0, teams: [AgentRoleTeam] = [sampleTeam]) -> AgentRolesOverview {
        let roles = (roles + reviewRoles).map { role in
            var role = role
            role.teamId = role.group.isEmpty ? "" : sampleTeam.id
            return role
        }
        return overview(revision: revision, roles: roles, capabilities: ["pr-review-agents-v1", "pr-review-teams-v1"], teams: teams)
    }

    static func overview(revision: Int = 0, roles: [AgentRole] = roles, machineID: String = "server-desktop",
                         capabilities: [String]? = nil, teams: [AgentRoleTeam]? = nil) -> AgentRolesOverview {
        AgentRolesOverview(ok: true, capability: "agent-roles-v1", machineId: machineID, revision: revision,
            roles: roles, skills: skills, sources: [], warnings: [], capabilities: capabilities, teams: teams)
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
    var issues: [AgentRoleSkillIssue] = []
    var suggestedSources: [AgentRoleSkillSource] = []
    var isLoading = false
    var bundledIDs: Set<String> = []
    /// Every `bundles(for:)` request, in order.
    var bundleRequests: [Set<String>] = []
    /// Skills whose packages can't be read.
    var unreadableIDs: Set<String> = []
    func refresh() async {}
    func addSource(_ url: URL, name: String?) throws {}
    func removeSource(_ id: String) {}
    func bundles(for ids: Set<String>) async throws -> [AgentRoleSkillBundle] {
        bundleRequests.append(ids)
        if !ids.isDisjoint(with: unreadableIDs) { throw AgentRoleCatalogError("A selected skill is unavailable on this Mac.") }
        bundledIDs = ids
        return skills.filter { ids.contains($0.id) }.map {
            AgentRoleSkillBundle(id: $0.id, name: $0.name, description: $0.description, source: $0.source,
                files: [.init(path: "SKILL.md", content: Data("Synthetic skill".utf8).base64EncodedString(), executable: false)])
        }
    }
}

actor AgentRoleTestClient: AgentRolesClient {
    struct ImportRequest: Sendable {
        let document: Data
        let dryRun: Bool
        let expectedRevision: Int?
        let planDigest: String?
        let roleIDs: [String]?
        let replaceRoleIDs: [String]?
        let localSkills: [String: String]?
    }

    private var overview: AgentRolesOverview
    private var mutations: [AgentRoleMutation] = []
    private var failure: APIError?
    private var mutationResponse: AgentRolesOverview?
    private var sharePreview: AgentRolesSharePreview?
    private var exportResult: Result<AgentRolesExport, APIError>?
    private var importResults: [Result<AgentRolesImportPlan, APIError>] = []
    private var exports: [[String]] = []
    private var imports: [ImportRequest] = []
    init(overview: AgentRolesOverview = AgentRoleTestFixtures.overview()) { self.overview = overview }
    func fail(with error: APIError?) { failure = error }
    func respondToMutation(with response: AgentRolesOverview) { mutationResponse = response }
    func recordedMutations() -> [AgentRoleMutation] { mutations }
    func respondToSharePreview(with preview: AgentRolesSharePreview) { sharePreview = preview }
    func respondToExport(with result: Result<AgentRolesExport, APIError>) { exportResult = result }
    /// Answered in order; the last answer repeats.
    func respondToImports(with results: [Result<AgentRolesImportPlan, APIError>]) { importResults = results }
    func recordedExports() -> [[String]] { exports }
    func recordedImports() -> [ImportRequest] { imports }

    func fetchAgentRolesSharePreview() async throws -> AgentRolesSharePreview {
        if let failure { throw failure }
        guard let sharePreview else { throw APIError.server(status: 404, message: "Not found") }
        return sharePreview
    }

    func exportAgentRoles(roleIDs: [String]) async throws -> AgentRolesExport {
        exports.append(roleIDs)
        if let failure { throw failure }
        guard let exportResult else { throw APIError.server(status: 404, message: "Not found") }
        return try exportResult.get()
    }

    func importAgentRoles(document: Data, dryRun: Bool, expectedRevision: Int?, planDigest: String?,
                          roleIDs: [String]?, replaceRoleIDs: [String]?,
                          localSkills: [String: String]?) async throws -> AgentRolesImportPlan {
        imports.append(.init(document: document, dryRun: dryRun, expectedRevision: expectedRevision,
                             planDigest: planDigest, roleIDs: roleIDs, replaceRoleIDs: replaceRoleIDs,
                             localSkills: localSkills))
        if let failure { throw failure }
        guard let result = importResults.first else { throw APIError.server(status: 404, message: "Not found") }
        if importResults.count > 1 { importResults.removeFirst() }
        let plan = try result.get()
        if let committed = plan.overview { overview = committed }
        return plan
    }
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
        var teams = overview.teams
        switch mutation.action {
        case "saveTeam":
            guard let team = mutation.team else { throw APIError.invalidResponse }
            teams = ((teams ?? []).filter { $0.id != team.id } + [team])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for index in roles.indices where roles[index].teamId == team.id { roles[index].group = team.name }
        case "deleteTeam":
            guard teams?.contains(where: { $0.id == mutation.teamId }) == true else {
                throw APIError.server(status: 404, message: "Team no longer exists")
            }
            teams?.removeAll { $0.id == mutation.teamId }
            for index in roles.indices where roles[index].teamId == mutation.teamId {
                roles[index].teamId = ""
                roles[index].group = ""
            }
        default:
            if let role = mutation.role {
                if let index = roles.firstIndex(where: { $0.id == role.id }) { roles[index] = role }
                else { roles.append(role) }
            } else { roles.removeAll { $0.id == mutation.roleId } }
        }
        overview = AgentRoleTestFixtures.overview(revision: overview.revision + 1, roles: roles, machineID: overview.machineId,
            capabilities: overview.capabilities, teams: teams)
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

// MARK: Sharing

extension AgentRoleTestFixtures {
    static let shareCapabilities = ["pr-review-agents-v1", "agent-roles-share-v1"]
    static let releaseNotesID = "aaaa0000-0000-4000-8000-000000000001"
    static let contrastID = "bbbb0000-0000-4000-8000-000000000002"
    static let schemaID = "cccc0000-0000-4000-8000-000000000003"

    /// A companion that can share roles.
    static func shareOverview(revision: Int = 7, roles: [AgentRole] = roles + reviewRoles,
                              skills: [AgentRoleSkill] = skills) -> AgentRolesOverview {
        AgentRolesOverview(ok: true, capability: "agent-roles-v1", machineId: "server-desktop", revision: revision,
            roles: roles, skills: skills, sources: [], warnings: [], capabilities: shareCapabilities)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    static func json(_ role: AgentRole) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(role))
    }

    static func sharePreview() throws -> AgentRolesSharePreview {
        func role(_ id: String, _ name: String, purpose: String = "worker", builtin: Bool = false, group: String = "",
                  avatar: String = "review", shareable: Bool = true, note: String = "", automatic: Bool = false,
                  skills: [[String: Any]] = []) -> [String: Any] {
            ["id": id, "name": name, "purpose": purpose, "builtin": builtin, "group": group, "avatar": avatar,
             "allowDelegation": false, "shareable": shareable, "note": note, "automaticSkills": automatic, "skills": skills]
        }
        let alpha: [String: Any] = ["id": "skill_alpha", "name": "Atlas notes", "included": true, "files": 3, "bytes": 18_234, "executable": 1]
        let absent: [String: Any] = ["id": "skill_absent", "name": "Sample linter", "included": false, "files": 0, "bytes": 0, "executable": 0]
        return try decode(AgentRolesSharePreview.self, [
            "ok": true, "machineId": "server-desktop", "revision": 7,
            "roles": [
                role("first_mate", "First Mate", builtin: true, shareable: false, note: "Default — nothing to share", automatic: true),
                role("worker", "Worker", builtin: true, skills: [alpha, absent]),
                role(releaseNotesID, "Release notes", automatic: true),
                role("pr-review-comprehensive", "Comprehensive", purpose: "pr_review", builtin: true, shareable: false,
                     note: "Default — nothing to share"),
                role("sample-review-agent", "Atlas", purpose: "pr_review", group: "Sample team", avatar: "quality", skills: [alpha]),
                role(contrastID, "Contrast checker", purpose: "pr_review", group: "Sample team", avatar: "design"),
                role(schemaID, "Schema reader", purpose: "pr_review", avatar: "data"),
            ],
            "warnings": ["Worker: the selected skill ‘Sample linter’ isn't stored on this computer, so only its name is shared."],
        ] as [String: Any])
    }

    /// A synthetic roles file, including a field this version doesn't know.
    static func shareDocument(format: String = "herdr-agent-roles", version: Any = 1) throws -> Data {
        let object: [String: Any] = [
            "format": format, "version": version, "exportedAt": "2026-10-02T21:00:00Z",
            "roles": [[
                "id": releaseNotesID, "builtin": false, "name": "Release notes", "purpose": "worker",
                "whenToUse": "Draft notes for a sample release.", "systemPrompt": "Summarize the sample release.",
                "modelProfile": "execution", "allowDelegation": true,
                "skillIds": ["skill_alpha", "skill_bravo", "skill_remote"],
                "skillContent": ["skill_alpha": String(repeating: "a", count: 64)],
            ]],
            "skills": [[
                "id": "skill_alpha", "name": "Atlas notes", "description": "Synthetic skill.", "source": "agents",
                "contentHash": String(repeating: "a", count: 64),
                "files": [["path": "SKILL.md", "content": Data("Synthetic skill".utf8).base64EncodedString(), "executable": false]],
            ]],
            "futureField": ["kept": true, "path": "scripts/run.sh"],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func planRole(_ id: String, _ name: String, action: String, purpose: String = "worker", builtin: Bool = false,
                         selected: Bool = false, role: AgentRole? = nil, current: AgentRole? = nil,
                         changes: [String] = [], team: (name: String, status: String)? = nil,
                         skills: [(id: String, name: String, outcome: String)] = [], reason: String = "",
                         notes: [String] = []) throws -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "name": name, "purpose": purpose, "builtin": builtin, "action": action, "reason": reason,
            "selectedByDefault": selected, "changes": changes, "notes": notes,
            "skills": skills.map { ["id": $0.id, "sourceId": $0.id, "name": $0.name, "outcome": $0.outcome] },
        ]
        object["role"] = try role.map(json) ?? NSNull()
        object["current"] = try current.map(json) ?? NSNull()
        object["team"] = team.map { ["name": $0.name, "status": $0.status] } ?? NSNull()
        return object
    }

    static func planSkill(_ id: String, _ name: String, outcome: String, sourceID: String? = nil,
                          files: [(path: String, bytes: Int, executable: Bool)] = [], skillText: String = "",
                          usedBy: [String] = []) -> [String: Any] {
        ["id": id, "sourceId": sourceID ?? id, "name": name, "description": "A synthetic skill for review.",
         "outcome": outcome, "files": files.map { ["path": $0.path, "bytes": $0.bytes, "executable": $0.executable] },
         "bytes": files.reduce(0) { $0 + $1.bytes }, "executableFiles": files.count { $0.executable },
         "skillText": skillText, "usedBy": usedBy]
    }

    static func importPlan(dryRun: Bool = true, revision: Int = 7, digest: String = String(repeating: "d", count: 64),
                           roles: [[String: Any]], skills: [[String: Any]] = [], warnings: [String] = [],
                           imported: [String: Int]? = nil, overview: AgentRolesOverview? = nil) throws -> AgentRolesImportPlan {
        var object: [String: Any] = [
            "ok": true, "dryRun": dryRun, "machineId": "server-desktop", "revision": revision, "planDigest": digest,
            "exportedAt": "2026-10-02T21:00:00Z", "roles": roles, "skills": skills,
            "teams": [["name": "Sample team", "status": "joins"], ["name": "Data team", "status": "creates"]],
            "warnings": warnings,
        ]
        if let imported { object["imported"] = imported }
        if let overview { object["overview"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overview)) }
        return try decode(AgentRolesImportPlan.self, object)
    }

    static func releaseNotesRole() -> AgentRole {
        AgentRole(id: releaseNotesID, builtin: false, locked: false, name: "Release notes",
                  whenToUse: "Draft notes for a sample release.", systemPrompt: "Summarize the sample release.",
                  modelProfile: "execution", allowDelegation: true, skillIds: ["skill_alpha"])
    }

    static func updatedWorker() -> AgentRole {
        var worker = roles[2]
        worker.systemPrompt = "Prefer small sample changes and explain each verification step."
        worker.skillIds = ["skill_bravo"]
        return worker
    }

    /// A create, an update with changes, unchanged roles, a skip, team headers and every skill outcome.
    static func importPlanRoles(releaseNotes: String = "create", planner: String = "unchanged") throws -> [[String: Any]] {
        let contrast = AgentRole(id: contrastID, builtin: false, locked: false, name: "Contrast checker", whenToUse: "",
            systemPrompt: "", modelProfile: "default", allowDelegation: false, skillIds: ["skill_charlie_copy"],
            purpose: "pr_review", reviewPrompt: "Check sample screens for contrast.\n\nPull request: {url}",
            group: "Sample team", avatar: "design")
        var atlas = reviewRoles[1]
        atlas.reviewPrompt = "Review the sample change for regressions and missing tests."
        return [
            try planRole(releaseNotesID, "Release notes", action: releaseNotes, selected: releaseNotes == "create",
                         role: releaseNotesRole(), current: releaseNotes == "update" ? releaseNotesRole() : nil,
                         changes: releaseNotes == "update" ? ["System prompt"] : [],
                         skills: [("skill_alpha", "Atlas notes", "present")]),
            try planRole("worker", "Worker", action: "update", builtin: true, role: updatedWorker(), current: roles[2],
                         changes: ["System prompt", "Skills"],
                         skills: [("skill_bravo", "Build compass", "included"), ("skill_gone", "Sample formatter", "missing")],
                         notes: ["Sample formatter isn't available on this computer, so Worker imports without it."]),
            try planRole("planner", "Planner", action: planner, builtin: true, role: roles[3], current: roles[3],
                         changes: planner == "update" ? ["When to use"] : []),
            try planRole("research_scout", "Research Scout", action: "unchanged", builtin: true, role: roles[5], current: roles[5]),
            try planRole("recovery_advisor", "Recovery Advisor", action: "skip", builtin: true,
                         reason: "Recovery Advisor is managed by each computer."),
            try planRole(contrastID, "Contrast checker", action: "create", purpose: "pr_review", selected: true, role: contrast,
                         team: ("Sample team", "joins"), skills: [("skill_charlie_copy", "Change summary", "separate")]),
            try planRole(schemaID, "Schema reader", action: "create", purpose: "pr_review", selected: true,
                         team: ("Data team", "creates")),
            try planRole("sample-review-agent", "Atlas", action: "update", purpose: "pr_review", role: atlas,
                         current: reviewRoles[1], changes: ["Review prompt"], team: ("Sample team", "joins"),
                         skills: [("skill_alpha", "Atlas notes", "available")]),
        ]
    }

    static func importPlanSkills() -> [[String: Any]] {
        [
            planSkill("skill_bravo", "Build compass", outcome: "included",
                      files: [("SKILL.md", 1_240, false), ("scripts/check-build.sh", 380, true)],
                      skillText: "---\nname: Build compass\ndescription: Inspect a sample project's build settings.\n---\n\nRead the sample build settings, then list the checks to run.",
                      usedBy: ["worker"]),
            planSkill("skill_charlie_copy", "Change summary", outcome: "separate", sourceID: "skill_charlie",
                      files: [("SKILL.md", 860, false)], usedBy: [contrastID]),
            planSkill("skill_alpha", "Atlas notes", outcome: "present", files: [("SKILL.md", 640, false)],
                      usedBy: [releaseNotesID]),
            planSkill("skill_gone", "Sample formatter", outcome: "missing", usedBy: ["worker"]),
        ]
    }

    static func samplePlan(releaseNotes: String = "create", planner: String = "unchanged",
                           digest: String = String(repeating: "d", count: 64)) throws -> AgentRolesImportPlan {
        try importPlan(digest: digest, roles: importPlanRoles(releaseNotes: releaseNotes, planner: planner),
                       skills: importPlanSkills(),
                       warnings: ["Ignored fields this companion doesn't understand: futureField."])
    }

    /// The commit response: the plan, the counts and the overview afterwards.
    static func committedPlan(created: Int = 2, updated: Int = 1) throws -> AgentRolesImportPlan {
        try importPlan(dryRun: false, roles: importPlanRoles(), skills: importPlanSkills(),
                       imported: ["created": created, "updated": updated, "unchanged": 2],
                       overview: shareOverview(revision: 8, roles: roles.map { $0.id == "worker" ? updatedWorker() : $0 }
                                                + [releaseNotesRole()] + reviewRoles))
    }
}
