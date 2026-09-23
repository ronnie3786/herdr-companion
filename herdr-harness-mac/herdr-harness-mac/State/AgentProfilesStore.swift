import Foundation
import Observation

/// Agent Profiles across every configured machine.
///
/// Each machine uses at most one profile, which may be owned by another
/// machine. The store loads every machine so it can resolve owners by their
/// server machine ID: profile edits go to the owner, while overrides and the
/// profile choice belong to the selected machine.
@MainActor
@Observable
final class AgentProfilesStore {
    enum MachineStatus: Equatable {
        case loading
        case loaded(AgentProfilesOverview)
        case unavailable(String)
        case needsUpdate
    }

    struct ProfileChoice: Identifiable, Equatable {
        let reference: AgentProfileReference
        let profile: AgentProfile
        let owner: HerdrMachine
        let users: [HerdrMachine]

        var id: String { "\(reference.ownerServerID)/\(reference.profileID)" }

        /// Every companion creates empty Personal and Work profiles. Unused,
        /// empty ones are tucked away so the choice list stays short.
        var isUnusedStarter: Bool { users.isEmpty && profile.soul.isEmpty && profile.user.isEmpty }
    }

    struct Suggestion: Identifiable, Equatable {
        let proposal: AgentProfileProposal
        let owner: HerdrMachine
        let current: AgentProfile?

        var id: String { proposal.id }
        var isOutdated: Bool { current?.revision != proposal.baseRevision }
    }

    let machines: [HerdrMachine]
    private(set) var selectedMachineID: String?
    private(set) var statuses: [String: MachineStatus] = [:]
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var conflictMessage: String?
    private(set) var history: [AgentProfile] = []
    private(set) var isLoadingHistory = false
    private(set) var historyError: String?

    var soulDraft = ""
    var userDraft = ""
    var overrideSoul = ""
    var overrideUser = ""

    private struct ProfileBaseline {
        let reference: AgentProfileReference
        let revision: Int
        let name: String
        let soul: String
        let user: String
    }

    private struct BindingBaseline {
        let revision: Int
        let ownerServerID: String?
        let profileID: String?
        let soul: String
        let user: String
    }

    private struct PendingMutation {
        let machineID: String
        let mutation: AgentProfileMutation
        let failure: String
    }

    private let clients: [String: any AgentProfilesClient]
    private var profileBaseline: ProfileBaseline?
    private var bindingBaseline: BindingBaseline?
    private var pendingMutation: PendingMutation?
    private var loadGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0

    convenience init(model: HerdrAppModel) {
        var clients: [String: any AgentProfilesClient] = [:]
        if model.isDemoMode {
            clients = AgentProfileFixtures.demoClients(for: model.machines)
        } else {
            for machine in model.machines {
                guard let configuration = model.firstMateConfiguration(machineID: machine.id) else { continue }
                clients[machine.id] = HerdrAPIClient(configuration: configuration)
            }
        }
        self.init(machines: model.machines, clients: clients)
    }

    init(
        machines: [HerdrMachine],
        clients: [String: any AgentProfilesClient] = [:],
        initiallySelectedMachineID: String? = nil
    ) {
        self.machines = machines
        self.clients = clients
        if let initiallySelectedMachineID,
           machines.contains(where: { $0.id == initiallySelectedMachineID }) {
            selectedMachineID = initiallySelectedMachineID
        } else {
            selectedMachineID = machines.first?.id
        }
    }

    // MARK: - Machines

    var selectedMachine: HerdrMachine? {
        machines.first { $0.id == selectedMachineID }
    }

    var selectedOverview: AgentProfilesOverview? {
        selectedMachineID.flatMap(overview(for:))
    }

    func status(for machineID: String) -> MachineStatus {
        if let status = statuses[machineID] { return status }
        return clients[machineID] == nil ? .unavailable(Self.noConnectionMessage) : .loading
    }

    func overview(for machineID: String) -> AgentProfilesOverview? {
        guard case let .loaded(overview) = statuses[machineID] else { return nil }
        return overview
    }

    func machine(forServerID serverID: String) -> HerdrMachine? {
        machines.first { overview(for: $0.id)?.machineId == serverID }
    }

    func activeReference(for machineID: String) -> AgentProfileReference? {
        guard let binding = overview(for: machineID)?.binding,
              let owner = binding.ownerMachineId,
              let profileID = binding.profileId else { return nil }
        return AgentProfileReference(ownerServerID: owner, profileID: profileID)
    }

    /// The owner's current copy when reachable, otherwise the copy the viewing
    /// machine last synced.
    func profile(for reference: AgentProfileReference, cachedOn machineID: String? = nil) -> AgentProfile? {
        if let owner = machine(forServerID: reference.ownerServerID),
           let profile = overview(for: owner.id)?.profiles.first(where: { $0.id == reference.profileID }) {
            return profile
        }
        guard let machineID = machineID ?? selectedMachineID,
              let overview = overview(for: machineID),
              overview.binding.ownerMachineId == reference.ownerServerID,
              let cached = overview.effective.profile,
              cached.id == reference.profileID else { return nil }
        return cached
    }

    func profileName(for machineID: String) -> String? {
        guard let reference = activeReference(for: machineID) else { return nil }
        return profile(for: reference, cachedOn: machineID)?.name ?? "Unknown profile"
    }

    func machinesUsing(_ reference: AgentProfileReference) -> [HerdrMachine] {
        machines.filter { activeReference(for: $0.id) == reference }
    }

    func ownerName(for reference: AgentProfileReference) -> String {
        machine(forServerID: reference.ownerServerID)?.name ?? reference.ownerServerID
    }

    var profileChoices: [ProfileChoice] {
        machines.flatMap { owner -> [ProfileChoice] in
            guard let overview = overview(for: owner.id) else { return [] }
            return overview.profiles.map { profile in
                let reference = AgentProfileReference(ownerServerID: overview.machineId, profileID: profile.id)
                return ProfileChoice(reference: reference, profile: profile, owner: owner, users: machinesUsing(reference))
            }
        }
    }

    // MARK: - The profile being edited

    var activeReference: AgentProfileReference? {
        selectedMachineID.flatMap(activeReference(for:))
    }

    /// Normally the selected machine's profile. A dirty draft stays attached
    /// to the profile it was started from, even if the machine is reassigned.
    var editingReference: AgentProfileReference? {
        profileBaseline?.reference ?? activeReference
    }

    var editingProfile: AgentProfile? {
        guard let editingReference else { return nil }
        return profile(for: editingReference)
    }

    var editingOwner: HerdrMachine? {
        editingReference.flatMap { machine(forServerID: $0.ownerServerID) }
    }

    /// Edits are written to the owner, so the owner must be reachable.
    var editingProfileIsEditable: Bool {
        guard let owner = editingOwner else { return false }
        return clients[owner.id] != nil && overview(for: owner.id) != nil
    }

    /// Why the profile can't be edited right now, when it can't.
    var editingOwnerNote: String? {
        guard let reference = editingReference, !editingProfileIsEditable else { return nil }
        if let owner = editingOwner, clients[owner.id] == nil {
            return "\(owner.name) has no saved connection in this app. This is the copy this machine last synced."
        }
        if isLoading { return "Loading the profile from its owner…" }
        return "\(ownerName(for: reference)) owns this profile and isn't reachable right now. This is the copy this machine last synced; editing returns when it's back."
    }

    var editingProfileIsShared: Bool {
        guard let reference = editingReference, let selectedOverview else { return false }
        return reference.ownerServerID != selectedOverview.machineId
    }

    var profileHasUnsavedChanges: Bool {
        guard let profileBaseline else { return false }
        return soulDraft != profileBaseline.soul || userDraft != profileBaseline.user
    }

    func hasUnsavedChanges(in document: AgentProfileDocument) -> Bool {
        guard let profileBaseline else { return false }
        return switch document {
        case .soul: soulDraft != profileBaseline.soul
        case .user: userDraft != profileBaseline.user
        }
    }

    var profileDraftIsBehindServer: Bool {
        guard profileHasUnsavedChanges,
              let profileBaseline,
              let latest = profile(for: profileBaseline.reference) else { return false }
        return latest.revision > profileBaseline.revision
    }

    var soulIsTooLong: Bool { !AgentProfileLimits.documentIsValid(soulDraft) }
    var userIsTooLong: Bool { !AgentProfileLimits.documentIsValid(userDraft) }

    var isLocked: Bool { isSaving || pendingMutation != nil }

    var canSaveProfile: Bool {
        profileHasUnsavedChanges && !soulIsTooLong && !userIsTooLong && !isLocked && editingProfileIsEditable
    }

    /// Rename and restore write from the saved copy, so they wait for a clean draft.
    var canChangeSavedProfile: Bool {
        !profileHasUnsavedChanges && !isLocked && editingProfileIsEditable && profileBaseline != nil
    }

    // MARK: - Machine-only additions

    var overridesHaveUnsavedChanges: Bool {
        guard let bindingBaseline else { return false }
        return overrideSoul != bindingBaseline.soul || overrideUser != bindingBaseline.user
    }

    var savedOverridesAreEmpty: Bool {
        guard let bindingBaseline else { return true }
        return bindingBaseline.soul.isEmpty && bindingBaseline.user.isEmpty
    }

    var canSaveOverrides: Bool {
        overridesHaveUnsavedChanges
            && AgentProfileLimits.documentIsValid(overrideSoul)
            && AgentProfileLimits.documentIsValid(overrideUser)
            && !isLocked
            && bindingBaseline != nil
    }

    var hasUnsavedChanges: Bool { profileHasUnsavedChanges || overridesHaveUnsavedChanges }

    // MARK: - Suggestions

    var suggestions: [Suggestion] {
        selectedMachineID.map(suggestions(for:)) ?? []
    }

    /// Pending agent suggestions for the machine's profile, plus any for other
    /// profiles the machine owns (proposals live on the owner only).
    func suggestions(for machineID: String) -> [Suggestion] {
        var result: [Suggestion] = []
        var seen = Set<String>()
        func collect(from owner: HerdrMachine, where include: (AgentProfileProposal) -> Bool) {
            guard let overview = overview(for: owner.id) else { return }
            for proposal in overview.proposals
            where proposal.status == "pending" && include(proposal) && seen.insert(proposal.id).inserted {
                let current = overview.profiles.first { $0.id == proposal.profileId }
                result.append(Suggestion(proposal: proposal, owner: owner, current: current))
            }
        }
        let reference = machineID == selectedMachineID ? editingReference : activeReference(for: machineID)
        if let reference, let owner = machine(forServerID: reference.ownerServerID) {
            collect(from: owner) { $0.profileId == reference.profileID }
        }
        if let machine = machines.first(where: { $0.id == machineID }) {
            collect(from: machine) { _ in true }
        }
        return result
    }

    /// Pending suggestions for the profile a machine's agents actually use.
    func suggestionCountForProfileUsed(on machineID: String) -> Int {
        guard let reference = activeReference(for: machineID),
              let owner = machine(forServerID: reference.ownerServerID),
              let overview = overview(for: owner.id) else { return 0 }
        return overview.proposals.count { $0.status == "pending" && $0.profileId == reference.profileID }
    }

    // MARK: - Pending and conflicting changes

    var hasPendingMutation: Bool { pendingMutation != nil }

    var pendingMutationMessage: String? {
        guard let pendingMutation else { return nil }
        let name = machines.first { $0.id == pendingMutation.machineID }?.name ?? pendingMutation.machineID
        return "\(name) didn't confirm the last change: \(pendingMutation.failure) Retry sends the same request, so it can't apply twice. Reload to check whether it went through."
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Gives up on an unconfirmed change. Edits, restores, approvals and
    /// profile switches are revision-checked, so a late duplicate cannot apply.
    func stopRetryingPendingMutation() {
        pendingMutation = nil
    }

    /// Everything unsaved, for copying before a reload.
    var unsavedEditsText: String {
        var sections: [String] = []
        if profileHasUnsavedChanges {
            sections.append("SOUL\n\n\(soulDraft)")
            sections.append("USER\n\n\(userDraft)")
        }
        if overridesHaveUnsavedChanges {
            sections.append("SOUL ADDITIONS FOR THIS MACHINE\n\n\(overrideSoul)")
            sections.append("USER ADDITIONS FOR THIS MACHINE\n\n\(overrideUser)")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Loading

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        for machine in machines where clients[machine.id] == nil {
            statuses[machine.id] = .unavailable(Self.noConnectionMessage)
        }
        let clients = clients
        await withTaskGroup(of: (String, Result<AgentProfilesOverview, any Error>).self) { group in
            for machine in machines {
                guard let client = clients[machine.id] else { continue }
                let machineID = machine.id
                group.addTask {
                    do { return (machineID, .success(try await client.fetchAgentProfiles())) }
                    catch { return (machineID, .failure(error)) }
                }
            }
            // Apply each machine as it answers so an offline machine never
            // holds up the others.
            for await (machineID, result) in group {
                guard generation == loadGeneration else { continue }
                statuses[machineID] = Self.status(from: result)
                reconcileDrafts()
            }
        }
    }

    func reloadDiscardingDrafts() async {
        conflictMessage = nil
        discardDrafts()
        await load()
    }

    func selectMachine(_ machineID: String) {
        guard machineID != selectedMachineID, machines.contains(where: { $0.id == machineID }) else { return }
        selectedMachineID = machineID
        profileBaseline = nil
        bindingBaseline = nil
        historyGeneration &+= 1
        history = []
        historyError = nil
        isLoadingHistory = false
        conflictMessage = nil
        errorMessage = nil
        reconcileDrafts()
    }

    func loadHistory() async {
        guard let reference = editingReference,
              let owner = machine(forServerID: reference.ownerServerID),
              let client = clients[owner.id] else {
            history = []
            return
        }
        historyGeneration &+= 1
        let generation = historyGeneration
        isLoadingHistory = true
        historyError = nil
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        do {
            let response = try await client.fetchAgentProfile(id: reference.profileID)
            guard generation == historyGeneration, editingReference == reference else { return }
            history = Array(response.history.prefix(100))
        } catch {
            guard generation == historyGeneration else { return }
            historyError = error.localizedDescription
        }
    }

    // MARK: - Drafts

    func revertProfile() {
        guard let profileBaseline else { return }
        soulDraft = profileBaseline.soul
        userDraft = profileBaseline.user
    }

    func revertOverrides() {
        guard let bindingBaseline else { return }
        overrideSoul = bindingBaseline.soul
        overrideUser = bindingBaseline.user
    }

    func discardDrafts() {
        profileBaseline = nil
        bindingBaseline = nil
        reconcileDrafts()
    }

    // MARK: - Changes

    func saveProfile() async {
        guard canSaveProfile, let baseline = profileBaseline, let owner = editingOwner else { return }
        await perform(
            .update(
                profileId: baseline.reference.profileID,
                expectedRevision: baseline.revision,
                name: baseline.name,
                soul: soulDraft,
                user: userDraft,
                reason: editReason(from: baseline),
                requestId: UUID()
            ),
            on: owner.id
        )
    }

    func rename(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChangeSavedProfile,
              AgentProfileLimits.nameIsValid(trimmed),
              let baseline = profileBaseline,
              trimmed != baseline.name,
              let owner = editingOwner else { return }
        await perform(
            .update(
                profileId: baseline.reference.profileID,
                expectedRevision: baseline.revision,
                name: trimmed,
                soul: baseline.soul,
                user: baseline.user,
                reason: "Renamed profile",
                requestId: UUID()
            ),
            on: owner.id
        )
    }

    func restore(_ revision: AgentProfile) async {
        guard canChangeSavedProfile, let baseline = profileBaseline, let owner = editingOwner else { return }
        await perform(
            .restore(
                profileId: baseline.reference.profileID,
                expectedRevision: baseline.revision,
                sourceRevision: revision.revision,
                reason: "Restored revision \(revision.revision)",
                requestId: UUID()
            ),
            on: owner.id
        )
    }

    /// Switches the selected machine to another profile, or to none. Saved
    /// machine-only additions are kept.
    func use(_ choice: ProfileChoice?) async {
        await assign(choice?.reference)
    }

    func saveOverrides() async {
        guard canSaveOverrides, let selectedMachineID, let binding = bindingBaseline else { return }
        await perform(
            .assign(
                expectedRevision: binding.revision,
                ownerMachineId: binding.ownerServerID,
                profileId: binding.profileID,
                soul: overrideSoul,
                user: overrideUser,
                requestId: UUID()
            ),
            on: selectedMachineID
        )
    }

    /// Creates an empty profile owned by the selected machine and switches the
    /// machine to it.
    func createProfile(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentProfileLimits.nameIsValid(trimmed), !hasUnsavedChanges, !isLocked,
              let selectedMachineID else { return }
        let mutation = AgentProfileMutation.create(
            name: trimmed, soul: "", user: "", reason: "Created in Herdr", requestId: UUID()
        )
        let response = await perform(mutation, on: selectedMachineID)
        await useCreatedProfile(from: response, on: selectedMachineID)
    }

    func syncNow() async {
        guard pendingMutation == nil else {
            errorMessage = "Retry the unconfirmed change before making another."
            return
        }
        guard let selectedMachineID, let overview = selectedOverview else { return }
        await perform(.sync(expectedRevision: overview.binding.revision, requestId: UUID()), on: selectedMachineID)
    }

    func approve(_ suggestion: Suggestion) async {
        guard !suggestion.isOutdated, let current = suggestion.current else { return }
        await perform(
            .approve(
                proposalId: suggestion.proposal.id,
                expectedRevision: current.revision,
                reason: "Approved in Herdr",
                requestId: UUID()
            ),
            on: suggestion.owner.id
        )
    }

    func decline(_ suggestion: Suggestion) async {
        await perform(
            .reject(proposalId: suggestion.proposal.id, reason: "Declined in Herdr", requestId: UUID()),
            on: suggestion.owner.id
        )
    }

    func retryPendingMutation() async {
        guard let pendingMutation else { return }
        let response = await perform(pendingMutation.mutation, on: pendingMutation.machineID, isRetry: true)
        if case .create = pendingMutation.mutation {
            await useCreatedProfile(from: response, on: pendingMutation.machineID)
        }
    }

    // MARK: - Private

    @discardableResult
    private func perform(
        _ mutation: AgentProfileMutation,
        on machineID: String,
        isRetry: Bool = false
    ) async -> AgentProfileMutationResponse? {
        guard !isSaving else { return nil }
        if pendingMutation != nil && !isRetry {
            errorMessage = "Retry the unconfirmed change before making another."
            return nil
        }
        let machineName = machines.first { $0.id == machineID }?.name ?? machineID
        guard let client = clients[machineID] else {
            errorMessage = "\(machineName) doesn't have a working connection."
            return nil
        }
        isSaving = true
        errorMessage = nil
        conflictMessage = nil
        let response: AgentProfileMutationResponse
        do {
            response = try await client.mutateAgentProfiles(mutation)
        } catch {
            isSaving = false
            handleFailure(error, of: mutation, on: machineID)
            return nil
        }
        pendingMutation = nil
        adopt(response, from: mutation, on: machineID)
        // The change is committed. Refreshing every machine can take as long
        // as the slowest one, so it happens after the lock is released.
        isSaving = false
        await refreshMachinesUsingChangedProfile(mutation, on: machineID)
        await load()
        return response
    }

    private func handleFailure(_ error: any Error, of mutation: AgentProfileMutation, on machineID: String) {
        if case let APIError.server(status, _) = error, status == 409 {
            pendingMutation = nil
            conflictMessage = "This changed somewhere else. Your edits are still here: copy them, then reload."
            return
        }
        if case let APIError.server(status, message) = error, (400..<500).contains(status), status != 408 {
            pendingMutation = nil
            errorMessage = APIError.server(status: status, message: message).localizedDescription
            return
        }
        if case .sync = mutation {
            // Syncing only refreshes a copy; it is safe to ask again.
            errorMessage = "Couldn't sync: \(error.localizedDescription)"
            return
        }
        // 5xx, malformed responses and transport failures can happen after
        // the server committed. Keep the exact request ID and payload.
        pendingMutation = PendingMutation(machineID: machineID, mutation: mutation, failure: error.localizedDescription)
    }

    private func assign(_ reference: AgentProfileReference?) async {
        guard !hasUnsavedChanges,
              let selectedMachineID,
              let binding = bindingBaseline,
              reference != activeReference else { return }
        await perform(
            .assign(
                expectedRevision: binding.revision,
                ownerMachineId: reference?.ownerServerID,
                profileId: reference?.profileID,
                soul: binding.soul,
                user: binding.user,
                requestId: UUID()
            ),
            on: selectedMachineID
        )
    }

    private func useCreatedProfile(from response: AgentProfileMutationResponse?, on machineID: String) async {
        guard let created = response?.profile,
              selectedMachineID == machineID,
              let serverID = overview(for: machineID)?.machineId else { return }
        await assign(AgentProfileReference(ownerServerID: serverID, profileID: created.id))
    }

    private func adopt(_ response: AgentProfileMutationResponse, from mutation: AgentProfileMutation, on machineID: String) {
        switch mutation {
        case .update, .restore:
            guard let profile = response.profile, let serverID = overview(for: machineID)?.machineId else { return }
            let reference = AgentProfileReference(ownerServerID: serverID, profileID: profile.id)
            guard profileBaseline?.reference == reference else { return }
            adoptProfile(profile, reference: reference)
        case .assign:
            guard machineID == selectedMachineID, let binding = response.binding else { return }
            adoptBinding(binding)
        default:
            return
        }
    }

    /// Machines using a shared profile refresh in the background; asking them
    /// now makes a saved edit show up everywhere right away. Best effort.
    private func refreshMachinesUsingChangedProfile(_ mutation: AgentProfileMutation, on ownerMachineID: String) async {
        let profileID: String?
        switch mutation {
        case let .update(id, _, _, _, _, _, _), let .restore(id, _, _, _, _):
            profileID = id
        case let .approve(proposalID, _, _, _):
            profileID = overview(for: ownerMachineID)?.proposals.first { $0.id == proposalID }?.profileId
        default:
            profileID = nil
        }
        guard let profileID, let ownerServerID = overview(for: ownerMachineID)?.machineId else { return }
        let reference = AgentProfileReference(ownerServerID: ownerServerID, profileID: profileID)
        let targets = machinesUsing(reference).compactMap { machine -> (any AgentProfilesClient, Int)? in
            guard machine.id != ownerMachineID,
                  let client = clients[machine.id],
                  let revision = overview(for: machine.id)?.binding.revision else { return nil }
            return (client, revision)
        }
        await withTaskGroup(of: Void.self) { group in
            for (client, revision) in targets {
                group.addTask {
                    _ = try? await client.mutateAgentProfiles(.sync(expectedRevision: revision, requestId: UUID()))
                }
            }
        }
    }

    /// Brings clean drafts up to date. A dirty draft keeps its base revision,
    /// and a machine answering with an older copy than the one already shown
    /// (for example while reloading after a save) never replaces it.
    private func reconcileDrafts() {
        if !profileHasUnsavedChanges {
            if let reference = activeReference, let profile = profile(for: reference) {
                if let profileBaseline, profileBaseline.reference == reference,
                   profile.revision < profileBaseline.revision {
                    // Keep the newer copy.
                } else {
                    adoptProfile(profile, reference: reference)
                }
            } else if profileBaseline?.reference != activeReference {
                profileBaseline = nil
                soulDraft = ""
                userDraft = ""
            }
        }
        if !overridesHaveUnsavedChanges {
            if let binding = selectedOverview?.binding {
                if let bindingBaseline, binding.revision < bindingBaseline.revision {
                    // Keep the newer binding.
                } else {
                    adoptBinding(binding)
                }
            } else {
                bindingBaseline = nil
                overrideSoul = ""
                overrideUser = ""
            }
        }
    }

    private func adoptProfile(_ profile: AgentProfile, reference: AgentProfileReference) {
        if profileBaseline?.reference != reference {
            historyGeneration &+= 1
            history = []
            historyError = nil
            isLoadingHistory = false
        }
        profileBaseline = ProfileBaseline(
            reference: reference,
            revision: profile.revision,
            name: profile.name,
            soul: profile.soul,
            user: profile.user
        )
        soulDraft = profile.soul
        userDraft = profile.user
    }

    private func adoptBinding(_ binding: AgentProfileBinding) {
        bindingBaseline = BindingBaseline(
            revision: binding.revision,
            ownerServerID: binding.ownerMachineId,
            profileID: binding.profileId,
            soul: binding.soul,
            user: binding.user
        )
        overrideSoul = binding.soul
        overrideUser = binding.user
    }

    private func editReason(from baseline: ProfileBaseline) -> String {
        switch (soulDraft != baseline.soul, userDraft != baseline.user) {
        case (true, true): "Edited Soul and User"
        case (true, false): "Edited Soul"
        default: "Edited User"
        }
    }

    private static let noConnectionMessage = "No saved connection for this machine."

    private static func status(from result: Result<AgentProfilesOverview, any Error>) -> MachineStatus {
        switch result {
        case let .success(overview):
            guard overview.ok, overview.capability == "agent-profiles-v1" else {
                return .unavailable(APIError.invalidResponse.localizedDescription)
            }
            return .loaded(overview)
        case let .failure(APIError.server(status, _)) where status == 404:
            return .needsUpdate
        case let .failure(error):
            return .unavailable(error.localizedDescription)
        }
    }
}
