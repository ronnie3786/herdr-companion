enum AgentProfileFixtures {
    static func overview(machineID: String) -> AgentProfilesOverview {
        let personal = AgentProfile(
            id: "00000000-0000-4000-8000-000000000001",
            name: "Personal",
            revision: 1,
            soul: "",
            user: "",
            updatedAt: "2026-09-22T12:00:00Z",
            actor: "operator",
            reason: "Created default profile"
        )
        let work = AgentProfile(
            id: "00000000-0000-4000-8000-000000000002",
            name: "Work",
            revision: 1,
            soul: "",
            user: "",
            updatedAt: "2026-09-22T12:00:00Z",
            actor: "operator",
            reason: "Created default profile"
        )
        let binding = AgentProfileBinding(
            revision: 0,
            ownerMachineId: nil,
            profileId: nil,
            soul: "",
            user: "",
            updatedAt: "2026-09-22T12:00:00Z"
        )
        return AgentProfilesOverview(
            ok: true,
            capability: "agent-profiles-v1",
            machineId: machineID,
            profiles: [personal, work],
            binding: binding,
            effective: AgentProfileEffective(
                profile: nil,
                binding: binding,
                prompt: "No shared profile is assigned.",
                syncStatus: "unassigned",
                lastSyncedAt: nil,
                error: nil
            ),
            proposals: []
        )
    }
}
