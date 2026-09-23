import Foundation
import Observation

@MainActor
@Observable
final class AgentProfilesStore {
    let machines: [HerdrMachine]
    var selectedMachineID: String?
    private(set) var overview: AgentProfilesOverview?
    private(set) var history: [AgentProfile] = []
    private(set) var ownerProfiles: [AgentProfile] = []
    private(set) var ownerMachineServerID: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isLoadingHistory = false
    private(set) var isLoadingOwnerProfiles = false
    private(set) var errorMessage: String?
    private(set) var conflictMessage: String?
    private(set) var requiresServerUpgrade = false
    private(set) var selectedProfileID: String?
    private(set) var isCreatingProfile = false
    var draft = AgentProfileDraft()
    var overrideSoul = ""
    var overrideUser = ""
    var assignmentEnabled = false
    var assignmentOwnerMachineID: String?
    var assignmentProfileID: String?
    var proposalDecisionReason = ""

    private struct PendingMutation {
        let machineID: String
        let mutation: AgentProfileMutation
        let preservingProfileDraft: Bool
        let preservingAssignmentDraft: Bool
    }

    private let clients: [String: any AgentProfilesClient]
    private let isDemoMode: Bool
    private var pendingMutation: PendingMutation?
    private var loadGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var ownerGeneration: UInt64 = 0
    private var loadedOwnerMachineID: String?
    private var baselineDraft = AgentProfileDraft()
    private var baselineProfileID: String?
    private var baselineProfileRevision: Int?
    private var baselineBindingRevision: Int?
    private var baselineOverrideSoul = ""
    private var baselineOverrideUser = ""
    private var baselineAssignmentEnabled = false
    private var baselineOwnerMachineServerID: String?
    private var baselineAssignmentProfileID: String?

    convenience init(model: HerdrAppModel) {
        var clients: [String: any AgentProfilesClient] = [:]
        if !model.isDemoMode {
            for machine in model.machines {
                guard let configuration = model.firstMateConfiguration(machineID: machine.id) else { continue }
                clients[machine.id] = HerdrAPIClient(configuration: configuration)
            }
        }
        self.init(machines: model.machines, clients: clients, isDemoMode: model.isDemoMode)
    }

    init(
        machines: [HerdrMachine],
        clients: [String: any AgentProfilesClient] = [:],
        isDemoMode: Bool = false,
        initiallySelectedMachineID: String? = nil
    ) {
        self.machines = machines
        self.clients = clients
        self.isDemoMode = isDemoMode
        if let initiallySelectedMachineID,
           machines.contains(where: { $0.id == initiallySelectedMachineID }) {
            selectedMachineID = initiallySelectedMachineID
        } else {
            selectedMachineID = machines.first?.id
        }
    }

    var selectedMachine: HerdrMachine? {
        guard let selectedMachineID else { return nil }
        return machines.first { $0.id == selectedMachineID }
    }

    var selectedProfile: AgentProfile? {
        guard let selectedProfileID else { return nil }
        return overview?.profiles.first { $0.id == selectedProfileID }
    }

    var pendingProposals: [AgentProfileProposal] {
        overview?.proposals.filter { $0.status == "pending" } ?? []
    }

    var hasUnsavedChanges: Bool {
        profileHasUnsavedChanges || assignmentHasUnsavedChanges
    }

    var profileHasUnsavedChanges: Bool {
        isCreatingProfile
            ? !draft.name.isEmpty || !draft.soul.isEmpty || !draft.user.isEmpty || !draft.reason.isEmpty
            : draft != baselineDraft
    }

    var assignmentHasUnsavedChanges: Bool {
        let selectedOwnerServerID = assignmentOwnerMachineID == selectedMachineID
            ? overview?.machineId
            : ownerMachineServerID
        return overrideSoul != baselineOverrideSoul
            || overrideUser != baselineOverrideUser
            || assignmentEnabled != baselineAssignmentEnabled
            || (assignmentEnabled && selectedOwnerServerID != baselineOwnerMachineServerID)
            || (assignmentEnabled && assignmentProfileID != baselineAssignmentProfileID)
    }

    var profileDraftCanSave: Bool {
        draft.nameIsValid
            && draft.reasonIsValid
            && draft.documentsAreValid
            && !isSaving
            && pendingMutation == nil
            && (isCreatingProfile || (baselineProfileID != nil && baselineProfileRevision != nil))
    }

    var proposalDecisionReasonIsValid: Bool {
        AgentProfileLimits.reasonIsValid(proposalDecisionReason)
    }

    var profileDraftBaseRevision: Int? { baselineProfileRevision }
    var assignmentDraftBaseRevision: Int? { baselineBindingRevision }

    var profileDraftIsBehindServer: Bool {
        guard profileHasUnsavedChanges,
              let baselineProfileRevision,
              let latestRevision = selectedProfile?.revision else { return false }
        return baselineProfileRevision != latestRevision
    }

    var assignmentDraftIsBehindServer: Bool {
        guard assignmentHasUnsavedChanges,
              let baselineBindingRevision,
              let latestRevision = overview?.binding.revision else { return false }
        return baselineBindingRevision != latestRevision
    }

    var hasPendingMutation: Bool { pendingMutation != nil }

    var pendingMutationMessage: String? {
        guard let pendingMutation else { return nil }
        let machineName = machines.first { $0.id == pendingMutation.machineID }?.name ?? pendingMutation.machineID
        return "The result from \(machineName) was lost. Retry sends the exact same request ID and payload."
    }

    var assignmentCanSave: Bool {
        guard !isSaving,
              pendingMutation == nil,
              overrideSoul.utf8.count <= AgentProfileLimits.maximumDocumentBytes,
              overrideUser.utf8.count <= AgentProfileLimits.maximumDocumentBytes else { return false }
        if !assignmentEnabled { return true }
        return selectedOwnerMachineServerID != nil && assignmentProfileID != nil
    }

    var selectedOwnerMachineServerID: String? {
        guard assignmentEnabled else { return nil }
        if assignmentOwnerMachineID == selectedMachineID { return overview?.machineId }
        return ownerMachineServerID
    }

    func load() async {
        guard let selectedMachineID else { return }
        await load(
            machineID: selectedMachineID,
            preservingProfileDraft: false,
            preservingAssignmentDraft: false
        )
    }

    func selectMachine(_ machineID: String) async {
        guard machineID != selectedMachineID, machines.contains(where: { $0.id == machineID }) else { return }
        selectedMachineID = machineID
        clearTargetState()
        await load(
            machineID: machineID,
            preservingProfileDraft: false,
            preservingAssignmentDraft: false
        )
    }

    func reloadDiscardingDraft() async {
        guard pendingMutation == nil, let selectedMachineID else { return }
        conflictMessage = nil
        await load(
            machineID: selectedMachineID,
            preservingProfileDraft: false,
            preservingAssignmentDraft: false
        )
    }

    func selectProfile(_ profileID: String) async {
        guard overview?.profiles.contains(where: { $0.id == profileID }) == true else { return }
        selectedProfileID = profileID
        isCreatingProfile = false
        if let profile = selectedProfile {
            setDraft(profile: profile)
        }
        await loadHistory(profileID: profileID)
    }

    func beginCreatingProfile() {
        historyGeneration &+= 1
        selectedProfileID = nil
        isCreatingProfile = true
        history = []
        draft = AgentProfileDraft()
        baselineDraft = draft
        baselineProfileID = nil
        baselineProfileRevision = nil
        conflictMessage = nil
        errorMessage = nil
    }

    func discardProfileDraft() {
        if isCreatingProfile {
            beginCreatingProfile()
        } else if let selectedProfile {
            setDraft(profile: selectedProfile)
        }
    }

    func chooseAssignmentOwner(_ machineID: String?) async {
        if machineID == loadedOwnerMachineID { return }
        let previousProfileID = assignmentProfileID
        let previousOwnerServerID = ownerMachineServerID
        assignmentOwnerMachineID = machineID
        assignmentProfileID = nil
        ownerProfiles = []
        ownerMachineServerID = nil
        loadedOwnerMachineID = nil
        errorMessage = nil
        guard assignmentEnabled, let machineID else { return }

        if machineID == selectedMachineID, let overview {
            ownerProfiles = overview.profiles
            ownerMachineServerID = overview.machineId
            loadedOwnerMachineID = machineID
            if previousOwnerServerID == overview.machineId,
               overview.profiles.contains(where: { $0.id == previousProfileID }) {
                assignmentProfileID = previousProfileID
            }
            return
        }

        ownerGeneration &+= 1
        let generation = ownerGeneration
        guard let client = clients[machineID] else {
            errorMessage = "That profile owner is not configured with a usable connection."
            return
        }
        isLoadingOwnerProfiles = true
        defer { if generation == ownerGeneration { isLoadingOwnerProfiles = false } }
        do {
            let response = try await client.fetchAgentProfiles()
            guard generation == ownerGeneration, assignmentOwnerMachineID == machineID else { return }
            guard response.capability == "agent-profiles-v1" else {
                throw APIError.invalidResponse
            }
            ownerProfiles = response.profiles
            ownerMachineServerID = response.machineId
            loadedOwnerMachineID = machineID
            if previousOwnerServerID == response.machineId,
               response.profiles.contains(where: { $0.id == previousProfileID }) {
                assignmentProfileID = previousProfileID
            }
        } catch {
            guard generation == ownerGeneration, assignmentOwnerMachineID == machineID else { return }
            present(error, rootRoute: true)
        }
    }

    func createOrUpdateProfile() async {
        guard profileDraftCanSave else { return }
        let mutation: AgentProfileMutation
        if isCreatingProfile {
            mutation = .create(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                soul: draft.soul,
                user: draft.user,
                reason: draft.reason,
                requestId: UUID()
            )
        } else if let baselineProfileID, let baselineProfileRevision {
            mutation = .update(
                profileId: baselineProfileID,
                expectedRevision: baselineProfileRevision,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                soul: draft.soul,
                user: draft.user,
                reason: draft.reason,
                requestId: UUID()
            )
        } else {
            return
        }
        await performMutation(
            mutation,
            preservingProfileDraft: false,
            preservingAssignmentDraft: true
        )
    }

    func restore(_ sourceRevision: Int) async {
        guard draft.reasonIsValid,
              let baselineProfileID,
              let baselineProfileRevision else { return }
        await performMutation(
            .restore(
                profileId: baselineProfileID,
                expectedRevision: baselineProfileRevision,
                sourceRevision: sourceRevision,
                reason: draft.reason,
                requestId: UUID()
            ),
            preservingProfileDraft: false,
            preservingAssignmentDraft: true
        )
    }

    func saveAssignment() async {
        guard assignmentCanSave, let baselineBindingRevision else { return }
        await performMutation(
            .assign(
                expectedRevision: baselineBindingRevision,
                ownerMachineId: selectedOwnerMachineServerID,
                profileId: assignmentEnabled ? assignmentProfileID : nil,
                soul: overrideSoul,
                user: overrideUser,
                requestId: UUID()
            ),
            preservingProfileDraft: true,
            preservingAssignmentDraft: false
        )
    }

    func syncNow() async {
        guard pendingMutation == nil, let overview else { return }
        await performMutation(
            .sync(expectedRevision: overview.binding.revision, requestId: UUID()),
            preservingProfileDraft: true,
            preservingAssignmentDraft: true
        )
    }

    func approve(_ proposal: AgentProfileProposal) async {
        guard pendingMutation == nil,
              proposalDecisionReasonIsValid,
              let profile = overview?.profiles.first(where: { $0.id == proposal.profileId }) else { return }
        await performMutation(
            .approve(
                proposalId: proposal.id,
                expectedRevision: profile.revision,
                reason: proposalDecisionReason,
                requestId: UUID()
            ),
            preservingProfileDraft: true,
            preservingAssignmentDraft: true
        )
    }

    func reject(_ proposal: AgentProfileProposal) async {
        guard pendingMutation == nil, proposalDecisionReasonIsValid else { return }
        await performMutation(
            .reject(proposalId: proposal.id, reason: proposalDecisionReason, requestId: UUID()),
            preservingProfileDraft: true,
            preservingAssignmentDraft: true
        )
    }

    func retryPendingMutation() async {
        guard let pendingMutation else { return }
        await performMutation(
            pendingMutation.mutation,
            preservingProfileDraft: pendingMutation.preservingProfileDraft,
            preservingAssignmentDraft: pendingMutation.preservingAssignmentDraft,
            targetMachineID: pendingMutation.machineID,
            isRetry: true
        )
    }

    func currentProfile(for proposal: AgentProfileProposal) -> AgentProfile? {
        overview?.profiles.first { $0.id == proposal.profileId }
    }

    private func load(
        machineID: String,
        preservingProfileDraft: Bool,
        preservingAssignmentDraft: Bool
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        requiresServerUpgrade = false
        defer { if generation == loadGeneration { isLoading = false } }

        if isDemoMode {
            guard generation == loadGeneration, selectedMachineID == machineID else { return }
            apply(
                AgentProfileFixtures.overview(machineID: machineID),
                preservingProfileDraft: preservingProfileDraft,
                preservingAssignmentDraft: preservingAssignmentDraft
            )
            if let selectedProfileID { await loadHistory(profileID: selectedProfileID) }
            return
        }

        guard let client = clients[machineID] else {
            errorMessage = "This machine does not have a usable authenticated connection."
            return
        }
        let response: AgentProfilesOverview
        do {
            response = try await client.fetchAgentProfiles()
            guard generation == loadGeneration, selectedMachineID == machineID else { return }
            guard response.ok, response.capability == "agent-profiles-v1" else {
                throw APIError.invalidResponse
            }
        } catch {
            guard generation == loadGeneration, selectedMachineID == machineID else { return }
            present(error, rootRoute: true)
            return
        }
        apply(
            response,
            preservingProfileDraft: preservingProfileDraft,
            preservingAssignmentDraft: preservingAssignmentDraft
        )
        if let selectedProfileID { await loadHistory(profileID: selectedProfileID) }
    }

    private func loadHistory(profileID: String) async {
        guard let selectedMachineID, let client = clients[selectedMachineID] else {
            if isDemoMode { history = selectedProfile.map { [$0] } ?? [] }
            return
        }
        historyGeneration &+= 1
        let generation = historyGeneration
        isLoadingHistory = true
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        do {
            let response = try await client.fetchAgentProfile(id: profileID)
            guard generation == historyGeneration,
                  self.selectedMachineID == selectedMachineID,
                  selectedProfileID == profileID else { return }
            history = Array(response.history.prefix(100))
        } catch {
            guard generation == historyGeneration, selectedProfileID == profileID else { return }
            present(error)
        }
    }

    private func performMutation(
        _ mutation: AgentProfileMutation,
        preservingProfileDraft: Bool,
        preservingAssignmentDraft: Bool,
        targetMachineID: String? = nil,
        isRetry: Bool = false
    ) async {
        guard !isSaving else { return }
        if pendingMutation != nil && !isRetry {
            errorMessage = "Resolve the uncertain Agent Profile request before making another change."
            return
        }
        guard let machineID = targetMachineID ?? selectedMachineID,
              let client = clients[machineID] else {
            if isDemoMode { errorMessage = "Agent Profile changes are disabled in demo mode." }
            else { errorMessage = "This machine does not have a usable authenticated connection." }
            return
        }
        let generation = loadGeneration
        isSaving = true
        errorMessage = nil
        conflictMessage = nil
        defer { isSaving = false }
        do {
            let mutationResponse = try await client.mutateAgentProfiles(mutation)
            pendingMutation = nil
            guard generation == loadGeneration, selectedMachineID == machineID else { return }
            if !preservingProfileDraft, let profile = mutationResponse.profile {
                selectedProfileID = profile.id
                isCreatingProfile = false
                setDraft(profile: profile)
            }
            if !preservingAssignmentDraft,
               let binding = mutationResponse.binding,
               let localMachineServerID = overview?.machineId {
                applyBinding(binding, localMachineServerID: localMachineServerID)
            }
            await load(
                machineID: machineID,
                preservingProfileDraft: preservingProfileDraft,
                preservingAssignmentDraft: preservingAssignmentDraft
            )
        } catch let APIError.server(status, message) where status == 409 {
            pendingMutation = nil
            let machineName = machines.first { $0.id == machineID }?.name ?? machineID
            conflictMessage = message.isEmpty
                ? "The profile changed on \(machineName). Your draft is preserved; reload to reconcile."
                : "\(message) Your draft is preserved; reload to reconcile."
        } catch let APIError.server(status, message) where (400..<500).contains(status) && status != 408 {
            pendingMutation = nil
            present(APIError.server(status: status, message: message))
        } catch {
            // 5xx, malformed responses and transport failures can occur after
            // commit. Retain the exact UUID/payload, not just transport errors.
            pendingMutation = PendingMutation(
                machineID: machineID,
                mutation: mutation,
                preservingProfileDraft: preservingProfileDraft,
                preservingAssignmentDraft: preservingAssignmentDraft
            )
            errorMessage = error.localizedDescription
        }
    }

    private func apply(
        _ response: AgentProfilesOverview,
        preservingProfileDraft: Bool,
        preservingAssignmentDraft: Bool
    ) {
        let previousProfileID = selectedProfileID
        let keepProfileDraft = preservingProfileDraft && profileHasUnsavedChanges
        let keepAssignmentDraft = preservingAssignmentDraft && assignmentHasUnsavedChanges
        overview = response
        requiresServerUpgrade = false
        errorMessage = nil

        if !keepProfileDraft {
            if let previousProfileID,
               response.profiles.contains(where: { $0.id == previousProfileID }) {
                selectedProfileID = previousProfileID
            } else {
                selectedProfileID = response.profiles.first?.id
            }
            isCreatingProfile = false
            if let selectedProfile { setDraft(profile: selectedProfile) }
            else {
                draft = AgentProfileDraft()
                baselineDraft = draft
                baselineProfileID = nil
                baselineProfileRevision = nil
            }
        }

        if !keepAssignmentDraft {
            applyBinding(response.binding, localMachineServerID: response.machineId)
        }

        if assignmentOwnerMachineID == selectedMachineID {
            ownerProfiles = response.profiles
            ownerMachineServerID = response.machineId
            loadedOwnerMachineID = selectedMachineID
        }

    }

    private func applyBinding(_ binding: AgentProfileBinding, localMachineServerID: String) {
        let knownOwnerMachineID = ownerMachineServerID == binding.ownerMachineId
            ? loadedOwnerMachineID
            : nil
        let knownOwnerProfiles = ownerProfiles
        overrideSoul = binding.soul
        overrideUser = binding.user
        assignmentEnabled = binding.ownerMachineId != nil && binding.profileId != nil
        if binding.ownerMachineId == localMachineServerID {
            assignmentOwnerMachineID = selectedMachineID
            ownerProfiles = overview?.profiles ?? []
            ownerMachineServerID = localMachineServerID
            loadedOwnerMachineID = selectedMachineID
        } else if let knownOwnerMachineID {
            assignmentOwnerMachineID = knownOwnerMachineID
            ownerProfiles = knownOwnerProfiles
            ownerMachineServerID = binding.ownerMachineId
            loadedOwnerMachineID = knownOwnerMachineID
        } else {
            assignmentOwnerMachineID = machines.first { $0.id == binding.ownerMachineId }?.id
            ownerProfiles = []
            ownerMachineServerID = binding.ownerMachineId
            loadedOwnerMachineID = nil
        }
        assignmentProfileID = binding.profileId
        baselineBindingRevision = binding.revision
        baselineOverrideSoul = overrideSoul
        baselineOverrideUser = overrideUser
        baselineAssignmentEnabled = assignmentEnabled
        baselineOwnerMachineServerID = binding.ownerMachineId
        baselineAssignmentProfileID = binding.profileId
    }

    private func setDraft(profile: AgentProfile) {
        draft = AgentProfileDraft(profile: profile)
        baselineDraft = draft
        baselineProfileID = profile.id
        baselineProfileRevision = profile.revision
        conflictMessage = nil
    }

    private func clearTargetState() {
        loadGeneration &+= 1
        historyGeneration &+= 1
        ownerGeneration &+= 1
        isLoading = false
        isLoadingHistory = false
        isLoadingOwnerProfiles = false
        overview = nil
        history = []
        ownerProfiles = []
        ownerMachineServerID = nil
        loadedOwnerMachineID = nil
        selectedProfileID = nil
        isCreatingProfile = false
        draft = AgentProfileDraft()
        baselineDraft = draft
        baselineProfileID = nil
        baselineProfileRevision = nil
        baselineBindingRevision = nil
        overrideSoul = ""
        overrideUser = ""
        baselineOverrideSoul = ""
        baselineOverrideUser = ""
        assignmentEnabled = false
        assignmentOwnerMachineID = nil
        assignmentProfileID = nil
        proposalDecisionReason = ""
        baselineAssignmentEnabled = false
        baselineOwnerMachineServerID = nil
        baselineAssignmentProfileID = nil
        errorMessage = nil
        conflictMessage = nil
        requiresServerUpgrade = false
    }

    private func present(_ error: any Error, rootRoute: Bool = false) {
        if rootRoute, case let APIError.server(status, _) = error, status == 404 {
            requiresServerUpgrade = true
            errorMessage = "Agent Profiles requires an updated companion server on this machine."
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
