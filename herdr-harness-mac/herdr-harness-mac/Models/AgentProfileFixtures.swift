import Foundation

/// Synthetic, in-memory Agent Profiles for demo mode. The first demo machine
/// owns a Personal and a Work profile; the second uses the first machine's
/// Work profile, so demo mode shows a shared profile and a pending suggestion.
enum AgentProfileFixtures {
    static let ownerServerID = "demo-desktop"
    static let sharedServerID = "demo-laptop"

    static func demoClients(for machines: [HerdrMachine]) -> [String: any AgentProfilesClient] {
        let serverIDs = [ownerServerID, sharedServerID]
        var clients: [String: any AgentProfilesClient] = [:]
        for (machine, serverID) in zip(machines, serverIDs) {
            clients[machine.id] = AgentProfilesDemoClient(serverID: serverID, world: .shared)
        }
        return clients
    }
}

struct AgentProfilesDemoClient: AgentProfilesClient {
    let serverID: String
    let world: AgentProfilesDemoWorld

    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        try await world.overview(serverID: serverID)
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        try await world.history(serverID: serverID, profileID: id)
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        try await world.mutate(serverID: serverID, mutation: mutation)
    }
}

actor AgentProfilesDemoWorld {
    static let shared = AgentProfilesDemoWorld()

    fileprivate struct Host {
        var history: [String: [AgentProfile]] = [:]
        var order: [String] = []
        var binding: AgentProfileBinding
        var proposals: [AgentProfileProposal] = []
        var lastSyncedAt: String?

        func current(_ profileID: String) -> AgentProfile? { history[profileID]?.first }
    }

    private var hosts: [String: Host] = [:]

    init() {
        let created = "2026-09-20T15:00:00Z"
        let personal = AgentProfile(
            id: "00000000-0000-4000-8000-00000000d001",
            name: "Personal",
            revision: 2,
            soul: """
            # Soul

            - Calm, direct, and a little dry.
            - Lead with the answer. Expand when asked.
            - Finish the whole job: tested, documented, tidy.
            - Ask before anything public or irreversible.
            """,
            user: """
            # User

            - Alex, product engineer in Denver (Mountain time).
            - Weekend projects: home automation and a vegetable garden.
            - Prefers short updates in plain English.
            """,
            updatedAt: "2026-09-22T18:30:00Z",
            actor: "operator",
            reason: "Edited Soul and User"
        )
        let work = AgentProfile(
            id: "00000000-0000-4000-8000-00000000d002",
            name: "Work",
            revision: 2,
            soul: """
            # Soul

            - Professional first. Light humor in small doses.
            - Push back with evidence.
            - Builds green and tests added before calling it done.
            """,
            user: """
            # User

            - Staff engineer on the mobile platform team.
            - Main repo: example/mobile-app. Tickets live in the team tracker.
            - Status updates: what changed, what's verified, what's left.
            """,
            updatedAt: "2026-09-22T19:05:00Z",
            actor: "operator",
            reason: "Edited Soul and User"
        )
        var owner = Host(binding: AgentProfileBinding(
            revision: 1, ownerMachineId: AgentProfileFixtures.ownerServerID, profileId: personal.id,
            soul: "", user: "", updatedAt: created
        ))
        owner.history = [
            personal.id: [personal, Self.starter(id: personal.id, name: "Personal", created: created)],
            work.id: [work, Self.starter(id: work.id, name: "Work", created: created)],
        ]
        owner.order = [personal.id, work.id]
        owner.proposals = [
            AgentProfileProposal(
                id: "00000000-0000-4000-8000-00000000d101",
                profileId: work.id,
                baseRevision: work.revision,
                soul: work.soul,
                user: work.user + "\n- PR review summaries go in the PR description, not chat.",
                reason: "Learned where review summaries belong",
                actor: "agent proposal",
                status: "pending",
                createdAt: "2026-09-23T09:12:00Z"
            ),
        ]

        var shared = Host(binding: AgentProfileBinding(
            revision: 1, ownerMachineId: AgentProfileFixtures.ownerServerID, profileId: work.id,
            soul: "", user: "", updatedAt: created
        ))
        let unusedStarter = Self.starter(id: "00000000-0000-4000-8000-00000000d003", name: "Personal", created: created)
        shared.history = [unusedStarter.id: [unusedStarter]]
        shared.order = [unusedStarter.id]
        shared.lastSyncedAt = "2026-09-23T09:00:00Z"

        hosts = [AgentProfileFixtures.ownerServerID: owner, AgentProfileFixtures.sharedServerID: shared]
    }

    func overview(serverID: String) throws -> AgentProfilesOverview {
        let host = try host(serverID)
        return AgentProfilesOverview(
            ok: true,
            capability: "agent-profiles-v1",
            machineId: serverID,
            profiles: host.order.compactMap { host.current($0) },
            binding: host.binding,
            effective: effective(serverID: serverID, host: host),
            proposals: host.proposals
        )
    }

    func history(serverID: String, profileID: String) throws -> AgentProfileHistoryResponse {
        let host = try host(serverID)
        guard let history = host.history[profileID], let profile = history.first else {
            throw APIError.server(status: 404, message: "Profile not found.")
        }
        return AgentProfileHistoryResponse(ok: true, profile: profile, history: history)
    }

    func mutate(serverID: String, mutation: AgentProfileMutation) throws -> AgentProfileMutationResponse {
        var host = try host(serverID)
        var profile: AgentProfile?
        var binding: AgentProfileBinding?
        var proposal: AgentProfileProposal?
        switch mutation {
        case let .create(name, soul, user, reason, _):
            let created = AgentProfile(
                id: UUID().uuidString.lowercased(), name: name, revision: 1, soul: soul, user: user,
                updatedAt: Self.now(), actor: "operator", reason: reason
            )
            host.history[created.id] = [created]
            host.order.append(created.id)
            profile = created
        case let .update(profileID, expectedRevision, name, soul, user, reason, _):
            profile = try host.commit(
                profileID: profileID, expectedRevision: expectedRevision,
                name: name, soul: soul, user: user, reason: reason
            )
        case let .restore(profileID, expectedRevision, sourceRevision, reason, _):
            guard let source = host.history[profileID]?.first(where: { $0.revision == sourceRevision }) else {
                throw APIError.server(status: 404, message: "That revision is no longer available.")
            }
            profile = try host.commit(
                profileID: profileID, expectedRevision: expectedRevision,
                name: source.name, soul: source.soul, user: source.user, reason: reason
            )
        case let .assign(expectedRevision, ownerMachineID, profileID, soul, user, _):
            guard expectedRevision == host.binding.revision else { throw Self.conflict }
            if let ownerMachineID, let profileID {
                let ownerHost = ownerMachineID == serverID ? host : hosts[ownerMachineID]
                guard ownerHost?.current(profileID) != nil else {
                    throw APIError.server(status: 404, message: "That profile is not available on its owner.")
                }
            }
            host.binding = AgentProfileBinding(
                revision: host.binding.revision + 1, ownerMachineId: ownerMachineID, profileId: profileID,
                soul: soul, user: user, updatedAt: Self.now()
            )
            if ownerMachineID != serverID { host.lastSyncedAt = Self.now() }
            binding = host.binding
        case let .sync(expectedRevision, _):
            guard expectedRevision == host.binding.revision else { throw Self.conflict }
            host.lastSyncedAt = Self.now()
        case let .propose(profileID, expectedRevision, soul, user, reason, _):
            let created = AgentProfileProposal(
                id: UUID().uuidString.lowercased(), profileId: profileID, baseRevision: expectedRevision,
                soul: soul, user: user, reason: reason, actor: "agent proposal", status: "pending",
                createdAt: Self.now()
            )
            host.proposals.append(created)
            proposal = created
        case let .approve(proposalID, expectedRevision, reason, _):
            guard let index = host.proposals.firstIndex(where: { $0.id == proposalID }),
                  let current = host.current(host.proposals[index].profileId) else {
                throw APIError.server(status: 404, message: "Suggestion not found.")
            }
            let pending = host.proposals[index]
            guard pending.baseRevision == expectedRevision else { throw Self.conflict }
            profile = try host.commit(
                profileID: pending.profileId, expectedRevision: expectedRevision,
                name: current.name, soul: pending.soul, user: pending.user, reason: reason
            )
            host.proposals[index] = pending.with(status: "accepted")
            proposal = host.proposals[index]
        case let .reject(proposalID, _, _):
            guard let index = host.proposals.firstIndex(where: { $0.id == proposalID }) else {
                throw APIError.server(status: 404, message: "Suggestion not found.")
            }
            host.proposals[index] = host.proposals[index].with(status: "rejected")
            proposal = host.proposals[index]
        }
        hosts[serverID] = host
        return AgentProfileMutationResponse(ok: true, profile: profile, binding: binding, effective: nil, proposal: proposal)
    }

    private func host(_ serverID: String) throws -> Host {
        guard let host = hosts[serverID] else { throw APIError.server(status: 404, message: "Not found.") }
        return host
    }

    private func effective(serverID: String, host: Host) -> AgentProfileEffective {
        let binding = host.binding
        var profile: AgentProfile?
        if let owner = binding.ownerMachineId, let profileID = binding.profileId {
            profile = (owner == serverID ? host : hosts[owner])?.current(profileID)
        }
        let status = if profile == nil { "unassigned" } else if binding.ownerMachineId == serverID { "local" } else { "current" }
        let sections = [
            profile.map { "SOUL.md\n\($0.soul)" },
            binding.soul.isEmpty ? nil : "SOUL additions for this machine\n\(binding.soul)",
            profile.map { "USER.md\n\($0.user)" },
            binding.user.isEmpty ? nil : "USER additions for this machine\n\(binding.user)",
        ].compactMap { $0 }
        return AgentProfileEffective(
            profile: profile,
            binding: binding,
            prompt: sections.joined(separator: "\n\n"),
            syncStatus: status,
            lastSyncedAt: status == "current" ? host.lastSyncedAt : nil,
            error: nil
        )
    }

    private static func starter(id: String, name: String, created: String) -> AgentProfile {
        AgentProfile(
            id: id, name: name, revision: 1, soul: "", user: "",
            updatedAt: created, actor: "system", reason: "Empty starter profile"
        )
    }

    fileprivate static let conflict = APIError.server(status: 409, message: "This changed since you opened it.")

    fileprivate static func now() -> String {
        ISO8601DateFormatter().string(from: .now)
    }
}

private extension AgentProfilesDemoWorld.Host {
    mutating func commit(
        profileID: String,
        expectedRevision: Int,
        name: String,
        soul: String,
        user: String,
        reason: String
    ) throws -> AgentProfile {
        guard let current = current(profileID) else {
            throw APIError.server(status: 404, message: "Profile not found.")
        }
        guard current.revision == expectedRevision else { throw AgentProfilesDemoWorld.conflict }
        let profile = AgentProfile(
            id: profileID, name: name, revision: current.revision + 1, soul: soul, user: user,
            updatedAt: AgentProfilesDemoWorld.now(), actor: "operator", reason: reason
        )
        history[profileID, default: []].insert(profile, at: 0)
        return profile
    }
}

private extension AgentProfileProposal {
    func with(status: String) -> AgentProfileProposal {
        AgentProfileProposal(
            id: id, profileId: profileId, baseRevision: baseRevision, soul: soul, user: user,
            reason: reason, actor: actor, status: status, createdAt: createdAt
        )
    }
}
