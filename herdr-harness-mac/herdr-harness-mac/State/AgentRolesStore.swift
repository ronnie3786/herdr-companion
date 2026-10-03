import Foundation
import Observation

@MainActor
@Observable
final class AgentRolesStore {
    enum Status: Equatable {
        case loading, loaded, needsUpdate, unavailable(String)
    }

    private(set) var machines: [HerdrMachine]
    let catalog: any AgentRoleSkillCatalog
    private(set) var selectedMachineID: String?
    private(set) var overview: AgentRolesOverview?
    private(set) var status = Status.loading
    private(set) var isSaving = false
    private(set) var isSavingTeams = false
    /// Team changes report here so their sheets can show the result.
    private(set) var teamErrorMessage: String?
    private(set) var errorMessage: String?
    private(set) var savedMessage: String?
    private(set) var hasConflict = false
    private(set) var requiresConnectionReload = false
    var draft: AgentRole?
    var search = ""
    var sourceFilter = ""

    private var clients: [String: any AgentRolesClient]
    private var configurations: [String: ServerConfiguration]
    private var retainedMachine: HerdrMachine?
    private var baseline: AgentRole?
    private var baselineRevision = 0
    private var generation: UInt64 = 0
    @ObservationIgnored private var skillSearch = AgentRoleSkillSearch()
    @ObservationIgnored private var searchCache: SkillSearchResults?

    private struct SkillSearchResults {
        let query: String
        let source: String
        let sections: [AgentRoleSkillSearch.Section]
        let skills: [AgentRoleSkill]
    }

    convenience init(model: HerdrAppModel) {
        self.init(machines: [], clients: [:], catalog: AgentRoleLocalCatalog())
        refreshConnections(model: model)
    }

    init(machines: [HerdrMachine], clients: [String: any AgentRolesClient],
         catalog: any AgentRoleSkillCatalog, initiallySelectedMachineID: String? = nil,
         configurations: [String: ServerConfiguration] = [:]) {
        self.machines = machines
        self.clients = clients
        self.configurations = configurations
        self.catalog = catalog
        selectedMachineID = machines.first(where: { $0.id == initiallySelectedMachineID })?.id ?? machines.first?.id
    }

    var selectedMachine: HerdrMachine? { machines.first { $0.id == selectedMachineID } ?? retainedMachine }
    var hasUnsavedChanges: Bool { draft != baseline }
    var isLoading: Bool { status == .loading }
    var supportsPRReviewAgents: Bool { overview?.supportsPRReviewAgents == true }
    var canCreatePRReviewRole: Bool {
        status == .loaded && supportsPRReviewAgents && !isSaving && !requiresConnectionReload
    }
    var canEdit: Bool {
        status == .loaded && draft?.locked == false && !isSaving && !requiresConnectionReload
            && (draft?.isPRReview != true || supportsPRReviewAgents)
    }
    var canSave: Bool {
        canEdit && hasUnsavedChanges && !hasConflict && !catalog.isLoading && validationMessage == nil
    }
    var canUpdateCopies: Bool {
        canEdit && !hasUnsavedChanges && !hasConflict && !catalog.isLoading
            && draft?.skillIds != nil && skills.contains { selectedIDs.contains($0.id) }
    }
    var validationMessage: String? {
        guard let draft else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give this role a name before saving." }
        if name.utf8.count > 120 || name.contains(where: \.isNewline) || name.contains("\t") {
            return "Use a single-line role name of at most 120 bytes."
        }
        if draft.whenToUse.utf8.count > 4096 { return "Shorten the when-to-use description to at most 4,096 bytes." }
        if draft.systemPrompt.utf8.count > 32768 { return "Shorten the system prompt to at most 32,768 bytes." }
        if draft.isPRReview {
            if !supportsPRReviewAgents { return "Update this companion to edit PR review agents." }
            if supportsTeams, let teamID = draft.teamId, !teamID.isEmpty, !teams.contains(where: { $0.id == teamID }) {
                return "This team was deleted. Choose another team."
            }
            if draft.group.utf8.count > 120 || draft.group.contains(where: \.isNewline) || draft.group.contains("\t") {
                return "Use a single-line team name of at most 120 bytes."
            }
            if draft.reviewPrompt.utf8.count > 32768 { return "Shorten the review prompt to at most 32,768 bytes." }
            if AgentRoleAvatar(rawValue: draft.avatar) == nil { return "Choose an available avatar." }
        }
        if selectedIDs.count > 2000 { return "Select no more than 2,000 skills per role." }
        return nil
    }
    var roles: [AgentRole] {
        var roles = (overview?.roles ?? []).map { $0.id == draft?.id ? draft ?? $0 : $0 }
        if let draft, !roles.contains(where: { $0.id == draft.id }) { roles.append(draft) }
        return roles
    }
    var skills: [AgentRoleSkill] { catalog.skills }
    var workerRoles: [AgentRole] { roles.filter { !$0.isPRReview } }
    var prReviewRoles: [AgentRole] { roles.filter(\.isPRReview) }
    var selectedIDs: Set<String> { Set(draft?.skillIds ?? []) }
    var selectedTokens: Int {
        let selected = selectedIDs
        return skills.filter { selected.contains($0.id) }.reduce(0) { $0 + max(0, $1.estimatedTokens) }
    }
    var allTokens: Int { skills.reduce(0) { $0 + max(0, $1.estimatedTokens) } }
    var missingIDs: [String] {
        selectedIDs.subtracting(Set(skills.map(\.id))).sorted()
    }
    var missingExecutionSkillIDs: [String] {
        guard let overview, let roleID = draft?.id else { return [] }
        if let missing = overview.missingRoleSkills {
            return selectedIDs.intersection(missing[roleID] ?? []).sorted()
        }
        // Older companions expose their available packages without per-role bindings.
        return selectedIDs.subtracting(Set(overview.skills.map(\.id))).sorted()
    }
    /// Letter sections while browsing; one best-first section while searching.
    var skillSections: [AgentRoleSkillSearch.Section] { skillSearchResults.sections }
    var filteredSkills: [AgentRoleSkill] { skillSearchResults.skills }
    var isSearchingSkills: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var letters: [String] { isSearchingSkills ? [] : skillSections.map(\.id) }
    var canChangeSkills: Bool { canEdit && draft?.skillIds != nil }
    var unsavedEditsText: String {
        guard let draft, let data = try? JSONEncoder().encode(draft) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Views read the results several times per render, so they are cached per
    /// catalog, query, and source. The index is rebuilt only when the catalog changes.
    private var skillSearchResults: SkillSearchResults {
        let skills = catalog.skills
        if skillSearch.skills != skills {
            skillSearch = AgentRoleSkillSearch(skills)
            searchCache = nil
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if let searchCache, searchCache.query == query, searchCache.source == sourceFilter { return searchCache }
        let sections = skillSearch.sections(query: query, source: sourceFilter)
        let results = SkillSearchResults(query: query, source: sourceFilter, sections: sections,
                                         skills: sections.flatMap(\.skills))
        searchCache = results
        return results
    }

    // MARK: Teams

    var supportsTeams: Bool { overview?.supportsPRReviewTeams == true }
    /// Saved teams. Older companions only know the team names agents already use.
    var teams: [AgentRoleTeam] {
        if supportsTeams { return overview?.teams ?? [] }
        let names = Set(prReviewRoles.map { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { AgentRoleTeam(id: $0, name: $0) }
    }
    /// Empty when the agent being edited has no team.
    var draftTeamID: String {
        (supportsTeams ? draft?.teamId : draft?.group.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
    var canEditTeams: Bool {
        status == .loaded && supportsTeams && !isSaving && !requiresConnectionReload && !hasConflict
    }

    func memberCount(ofTeam id: String) -> Int {
        prReviewRoles.filter { supportsTeams ? $0.teamId == id : $0.group.trimmingCharacters(in: .whitespacesAndNewlines) == id }.count
    }

    func assignTeam(_ id: String) {
        guard canEdit, draft?.isPRReview == true else { return }
        guard supportsTeams else {
            draft?.group = id
            return
        }
        guard id.isEmpty || teams.contains(where: { $0.id == id }) else { return }
        draft?.teamId = id
        draft?.group = teams.first { $0.id == id }?.name ?? ""
    }

    func teamNameProblem(_ name: String, renaming id: String? = nil) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a team name." }
        if name.utf8.count > 120 || name.contains(where: \.isNewline) || name.contains("\t") {
            return "Use a single-line team name of at most 120 bytes."
        }
        if teams.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A team with this name already exists."
        }
        return nil
    }

    /// Saves a new team on the companion, then optionally puts the agent being
    /// edited on it. Older companions store the name when the agent is saved.
    @discardableResult
    func createTeam(named name: String, assigningDraft: Bool = true) async -> Bool {
        guard teamNameProblem(name) == nil else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsTeams else {
            guard assigningDraft, canEdit, draft?.isPRReview == true else { return false }
            draft?.group = name
            return true
        }
        let team = AgentRoleTeam(id: UUID().uuidString.lowercased(), name: name)
        guard await mutateTeams(AgentRoleMutation(action: "saveTeam", expectedRevision: 0, role: nil, roleId: nil,
                                                  skillBundles: [], team: team)) else { return false }
        if assigningDraft { assignTeam(team.id) }
        return true
    }

    @discardableResult
    func renameTeam(_ id: String, to name: String) async -> Bool {
        guard teams.contains(where: { $0.id == id }), teamNameProblem(name, renaming: id) == nil else { return false }
        let team = AgentRoleTeam(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        return await mutateTeams(AgentRoleMutation(action: "saveTeam", expectedRevision: 0, role: nil, roleId: nil,
                                                   skillBundles: [], team: team))
    }

    /// Agents on a deleted team keep their other settings and have no team.
    @discardableResult
    func deleteTeam(_ id: String) async -> Bool {
        guard teams.contains(where: { $0.id == id }) else { return false }
        return await mutateTeams(AgentRoleMutation(action: "deleteTeam", expectedRevision: 0, role: nil, roleId: nil,
                                                   skillBundles: [], teamId: id))
    }

    func clearTeamError() { teamErrorMessage = nil }

    func sourceName(_ id: String) -> String { catalog.sources.first { $0.id == id }?.name ?? id }
    func missingSkillName(_ id: String) -> String { overview?.skills.first { $0.id == id }?.name ?? id }

    /// Re-read saved credentials when entering the pane or explicitly reloading.
    /// Comparisons stay in memory, without exposing connection URLs or tokens.
    func refreshConnections(model: HerdrAppModel) {
        var configurations: [String: ServerConfiguration] = [:]
        var clients: [String: any AgentRolesClient] = [:]
        for machine in model.machines {
            guard let configuration = model.firstMateConfiguration(machineID: machine.id) else { continue }
            configurations[machine.id] = configuration
            clients[machine.id] = HerdrAPIClient(configuration: configuration)
        }
        refreshConnections(machines: model.machines, configurations: configurations, clients: clients)
    }

    func refreshConnections(machines: [HerdrMachine], configurations: [String: ServerConfiguration],
                            clients: [String: any AgentRolesClient]) {
        // The pane retries this after an in-flight save finishes.
        guard !isSaving else { return }
        let previousMachine = selectedMachine
        let selectedID = selectedMachineID
        let selectedExists = machines.contains { $0.id == selectedID }
        let connectionChanged = selectedID.map {
            self.configurations[$0] != configurations[$0] || (self.clients[$0] == nil) != (clients[$0] == nil)
        } ?? false
        self.machines = machines
        self.configurations = configurations
        self.clients = clients
        guard !selectedExists || connectionChanged else { return }
        generation &+= 1
        if hasUnsavedChanges {
            retainedMachine = previousMachine
            requiresConnectionReload = true
            status = .loaded
            savedMessage = nil
            errorMessage = "This machine's connection changed or was removed. Your edits still belong to the previous connection. Copy your edits, then discard and reload before saving to a new connection."
        } else {
            resetForCurrentConnection()
        }
    }

    func loadIfNeeded() async {
        guard overview == nil, !isSaving else { return }
        await load()
    }

    func load() async {
        guard !isSaving, !requiresConnectionReload, let machineID = selectedMachineID else { return }
        generation &+= 1
        let currentGeneration = generation
        status = .loading
        guard let client = clients[machineID] else {
            status = .unavailable("No saved connection for this machine. Add its connection in Settings › Machines.")
            return
        }
        do {
            let response = try await client.fetchAgentRoles().validated()
            guard generation == currentGeneration, selectedMachineID == machineID else { return }
            overview = response
            status = .loaded
            if !hasUnsavedChanges { adopt(response.roles.first { $0.id == draft?.id } ?? response.roles.first) }
        } catch {
            guard generation == currentGeneration, selectedMachineID == machineID else { return }
            if case APIError.server(404, _) = error { status = .needsUpdate }
            else { status = .unavailable(error.localizedDescription) }
        }
    }

    /// Navigation callers confirm any discard first. The store also refuses to
    /// discard implicitly, so keyboard or future navigation cannot lose edits.
    func selectMachine(_ id: String) async {
        guard !isSaving, !hasUnsavedChanges,
              machines.contains(where: { $0.id == id }) else { return }
        if id == selectedMachineID {
            await loadIfNeeded()
            return
        }
        generation &+= 1
        selectedMachineID = id
        overview = nil
        adopt(nil)
        await load()
    }

    func selectRole(_ id: String) {
        guard !isSaving, !requiresConnectionReload, !hasUnsavedChanges,
              let role = overview?.roles.first(where: { $0.id == id }) else { return }
        adopt(role)
    }

    func newRole() {
        guard status == .loaded, !requiresConnectionReload, !isSaving, !hasUnsavedChanges else { return }
        baseline = nil
        baselineRevision = overview?.revision ?? 0
        draft = withTeamField(.custom())
        clearError()
    }

    func newPRReviewRole() {
        guard canCreatePRReviewRole, !hasUnsavedChanges else { return }
        baseline = nil
        baselineRevision = overview?.revision ?? 0
        draft = withTeamField(.customPRReview())
        clearError()
    }

    func discard() {
        guard !isSaving else { return }
        if requiresConnectionReload {
            resetForCurrentConnection()
            return
        }
        adopt(overview?.roles.first { $0.id == draft?.id } ?? overview?.roles.first)
    }

    private func resetForCurrentConnection() {
        if !machines.contains(where: { $0.id == selectedMachineID }) { selectedMachineID = machines.first?.id }
        retainedMachine = nil
        requiresConnectionReload = false
        overview = nil
        status = .loading
        adopt(nil)
    }

    func configureSelection() {
        guard canEdit, draft?.skillIds == nil else { return }
        draft?.skillIds = []
    }

    func toggleSkill(_ id: String) {
        guard canChangeSkills else { return }
        var ids = selectedIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        draft?.skillIds = ids.sorted()
    }

    func selectShown() {
        guard canChangeSkills else { return }
        let ids = selectedIDs.union(filteredSkills.map(\.id)).sorted()
        draft?.skillIds = ids
    }

    func clearSkills() {
        guard canChangeSkills else { return }
        draft?.skillIds = []
    }

    func copySkills(from role: AgentRole) {
        guard canChangeSkills, !role.locked, let ids = role.skillIds else { return }
        draft?.skillIds = ids
    }

    func save() async {
        guard canSave, var role = draft else { return }
        role.name = role.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if role.isPRReview { role.group = role.group.trimmingCharacters(in: .whitespacesAndNewlines) }
        await mutate(role: role, deleting: false)
    }

    func updateCopies() async {
        guard canUpdateCopies, let role = draft else { return }
        await mutate(role: role, deleting: false)
    }

    func deleteRole() async {
        guard canEdit, let role = draft, !role.builtin else { return }
        if baseline == nil { discard(); return }
        await mutate(role: role, deleting: true)
    }

    private func mutate(role: AgentRole, deleting: Bool) async {
        guard let machineID = selectedMachineID, let client = clients[machineID] else { return }
        isSaving = true
        clearError()
        let currentGeneration = generation
        defer { if generation == currentGeneration { isSaving = false } }
        do {
            let bundles = deleting ? [] : try await catalog.bundles(for: Set(role.skillIds ?? []).intersection(skills.map(\.id)))
            let mutation = AgentRoleMutation(action: deleting ? "delete" : "save",
                expectedRevision: baselineRevision, role: deleting ? nil : role,
                roleId: deleting ? role.id : nil, skillBundles: bundles)
            let response = try await client.mutateAgentRoles(mutation).validated()
            guard generation == currentGeneration, selectedMachineID == machineID else { return }
            guard response.revision > baselineRevision,
                  deleting ? !response.roles.contains(where: { $0.id == role.id }) : response.roles.first(where: { $0.id == role.id }) == role
            else { throw APIError.invalidResponse }
            overview = response
            status = .loaded
            adopt(deleting ? response.roles.first : response.roles.first { $0.id == role.id })
            savedMessage = "Saved to \(selectedMachine?.name ?? "the execution computer"). Applies to new sessions."
        } catch {
            guard generation == currentGeneration else { return }
            if case APIError.server(409, _) = error {
                hasConflict = true
                errorMessage = "These roles changed elsewhere. Your edits are still here. Copy your edits, then reload to get the latest version."
            } else {
                errorMessage = "The change wasn't confirmed. Your edits are still here. \(error.localizedDescription)"
            }
        }
    }

    /// Companions with saved teams return every role with a team ID, so new
    /// drafts carry one too and the saved role compares equal to the draft.
    private func withTeamField(_ role: AgentRole) -> AgentRole {
        var role = role
        if supportsTeams { role.teamId = "" }
        return role
    }

    /// Team saves share the role revision. When this change is the only one since
    /// the editor loaded, the editor moves to the new revision and keeps its edits.
    private func mutateTeams(_ request: AgentRoleMutation) async -> Bool {
        guard canEditTeams, let previous = overview, let machineID = selectedMachineID,
              let client = clients[machineID] else { return false }
        isSaving = true
        isSavingTeams = true
        teamErrorMessage = nil
        savedMessage = nil
        let currentGeneration = generation
        defer {
            if generation == currentGeneration {
                isSaving = false
                isSavingTeams = false
            }
        }
        let mutation = AgentRoleMutation(action: request.action, expectedRevision: previous.revision, role: nil, roleId: nil,
                                         skillBundles: [], team: request.team, teamId: request.teamId)
        do {
            let response = try await client.mutateAgentRoles(mutation).validated()
            guard generation == currentGeneration, selectedMachineID == machineID else { return false }
            let savedTeams = response.teams ?? []
            let confirmed = request.team.map { savedTeams.contains($0) }
                ?? !savedTeams.contains { $0.id == request.teamId }
            guard response.revision > previous.revision, response.supportsPRReviewTeams, confirmed
            else { throw APIError.invalidResponse }
            let wasClean = !hasUnsavedChanges
            let editorIsCurrent = baselineRevision == previous.revision && response.revision == previous.revision + 1
            overview = response
            if wasClean {
                adopt(response.roles.first { $0.id == draft?.id } ?? response.roles.first)
            } else if editorIsCurrent {
                baselineRevision = response.revision
                if let id = baseline?.id { baseline = response.roles.first { $0.id == id } }
                // Team names are derived from the team, so follow renames and deletions.
                if let teamID = draft?.teamId, !teamID.isEmpty {
                    let team = savedTeams.first { $0.id == teamID }
                    draft?.teamId = team?.id ?? ""
                    draft?.group = team?.name ?? ""
                }
            }
            return true
        } catch {
            guard generation == currentGeneration else { return false }
            if case APIError.server(409, _) = error {
                teamErrorMessage = "Agent Roles changed elsewhere. Reload, then try again. Your edits are still here."
            } else {
                teamErrorMessage = "The team change wasn't confirmed. \(error.localizedDescription)"
            }
            return false
        }
    }

    private func adopt(_ role: AgentRole?) {
        baseline = role
        draft = role
        baselineRevision = overview?.revision ?? 0
        clearError()
    }

    private func clearError() {
        errorMessage = nil
        hasConflict = false
        savedMessage = nil
    }
}
