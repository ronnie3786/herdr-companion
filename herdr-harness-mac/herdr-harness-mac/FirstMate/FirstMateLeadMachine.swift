import Foundation

/// Mac-only preference and local-companion policy. Shared choice rules are unchanged.
extension FirstMateLeadMachine {
    /// The machine chosen in the lead chat's header, if any.
    static let pinnedKey = "herdr.mac.firstMate.lead.pinned"

    @MainActor
    static func choice(hosts: [FirstMateFleetHost], machines: [HerdrMachine], defaults: UserDefaults = .standard) -> Choice {
        choose(capable: capable(hosts: hosts),
               offline: offline(hosts: hosts),
               pinned: pinned(defaults: defaults),
               local: home(localMachineID(machines: machines), hosts: hosts),
               withConversation: Set(hosts.filter { $0.lead != nil }.map(\.machineID)),
               activeCounts: activeCounts(hosts: hosts))
    }

    @MainActor
    static func current(hosts: [FirstMateFleetHost], machines: [HerdrMachine], defaults: UserDefaults = .standard) -> String? {
        choice(hosts: hosts, machines: machines, defaults: defaults).current
    }

    @MainActor
    static func pinned(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: pinnedKey)
    }

    /// Keeps the lead on `machineID`, or with nil returns to automatic.
    @MainActor
    static func pin(_ machineID: String?, defaults: UserDefaults = .standard) {
        if let machineID {
            defaults.set(machineID, forKey: pinnedKey)
        } else {
            defaults.removeObject(forKey: pinnedKey)
        }
    }

    /// This Mac's own configured machine, from host evidence read once per
    /// process (the same unique-match rule as a new HUD chat).
    @MainActor
    static func localMachineID(machines: [HerdrMachine]) -> String? {
        HerdrHudNewChatPolicy(hostIdentity: hostIdentity).localMachine(in: machines)?.id
    }

    @MainActor private static let hostIdentity = HerdrHudHostIdentity.current()
}
