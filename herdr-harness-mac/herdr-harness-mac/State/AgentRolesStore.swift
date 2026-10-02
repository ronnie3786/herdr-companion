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
        skills.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + max(0, $1.estimatedTokens) }
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
    var filteredSkills: [AgentRoleSkill] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.filter { skill in
            (sourceFilter.isEmpty || skill.source == sourceFilter)
                && (query.isEmpty || skill.name.localizedStandardContains(query)
                    || skill.description.localizedStandardContains(query))
        }.sorted { lhs, rhs in
            if lhs.letter != rhs.letter { return lhs.letter < rhs.letter }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
    var letters: [String] { Array(Set(filteredSkills.map(\.letter))).sorted() }
    var canChangeSkills: Bool { canEdit && draft?.skillIds != nil }
    var unsavedEditsText: String {
        guard let draft, let data = try? JSONEncoder().encode(draft) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

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
        draft = .custom()
        clearError()
    }

    func newPRReviewRole() {
        guard canCreatePRReviewRole, !hasUnsavedChanges else { return }
        baseline = nil
        baselineRevision = overview?.revision ?? 0
        draft = .customPRReview()
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
