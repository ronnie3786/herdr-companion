import Foundation

/// Which machine's lead First Mate the chat window and the HUD talk to, and
/// what it is told about the others.
///
/// A lead lives on one companion. It reads and relays to that machine's
/// features and to every other machine its companion holds a credential for
/// (the lead's `peers`). So the lead lives on this Mac's own companion once
/// it advertises `first-mate-lead-peers-v1`: it is up whenever you are here,
/// and a machine going down takes only its own features with it. A machine
/// chosen in the lead chat's header overrides that until Automatic is chosen
/// again. Otherwise (no companion on this Mac, or an older one) the lead
/// stays where a conversation already is, else on the busiest machine.
///
/// While that machine is offline, the Mac talks to the next machine's lead
/// instead and returns once it answers again. Nil means no machine has a lead
/// yet (older companions), and both surfaces keep their Phase 1 behavior.
enum FirstMateLeadMachine {
    /// The machine chosen in the lead chat's header, if any.
    static let pinnedKey = "herdr.mac.firstMate.lead.pinned"
    /// Failed polls in a row after which a machine counts as offline, so one
    /// dropped poll never moves the conversation.
    static let offlineAfterFailedPolls = 2

    struct Choice: Equatable {
        /// The machine the Mac talks to, or nil when no machine has a lead.
        var current: String?
        /// Where the lead lives when every machine answers.
        var preferred: String?

        /// The preferred machine is offline and another machine's lead is
        /// standing in.
        var isFallback: Bool { current != nil && preferred != nil && current != preferred }
    }

    static func choose(capable: [String], offline: Set<String> = [], pinned: String?, local: String?,
                       withConversation: Set<String> = [], activeCounts: [String: Int] = [:]) -> Choice {
        func first(in machines: [String], pinned: String?) -> String? {
            if let pinned, machines.contains(pinned) { return pinned }
            if let local, machines.contains(local) { return local }
            let existing = machines.filter(withConversation.contains)
            return busiest(existing.isEmpty ? machines : existing, activeCounts: activeCounts)
        }
        let preferred = first(in: capable, pinned: pinned)
        if let preferred, !offline.contains(preferred) { return Choice(current: preferred, preferred: preferred) }
        // With nothing reachable, stay where the conversation is and show it offline.
        let standIn = first(in: capable.filter { !offline.contains($0) }, pinned: nil)
        return Choice(current: standIn ?? preferred, preferred: preferred)
    }

    private static func busiest(_ machines: [String], activeCounts: [String: Int]) -> String? {
        let most = machines.map { activeCounts[$0] ?? 0 }.max() ?? 0
        return machines.first { (activeCounts[$0] ?? 0) == most }
    }

    /// Machines whose companion advertises `first-mate-lead-v1`, in roster order.
    static func capable(hosts: [FirstMateFleetHost]) -> [String] {
        hosts.filter(\.supportsLead).map(\.machineID)
    }

    /// Machines that failed ``offlineAfterFailedPolls`` polls in a row.
    static func offline(hosts: [FirstMateFleetHost]) -> Set<String> {
        Set(hosts.filter { $0.failedPolls >= offlineAfterFailedPolls }.map(\.machineID))
    }

    /// Features that are not done or archived, per machine.
    static func activeCounts(hosts: [FirstMateFleetHost]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for host in hosts {
            if let entries = host.fleetEntries {
                counts[host.machineID] = entries.values.filter { $0.hudStatus != .done && $0.archivedAt == nil }.count
            } else {
                counts[host.machineID] = host.features.filter { feature in
                    !feature.isArchived && feature.status != "completed" && feature.status != "cancelled"
                }.count
            }
        }
        return counts
    }

    @MainActor
    static func choice(hosts: [FirstMateFleetHost], machines: [HerdrMachine], defaults: UserDefaults = .standard) -> Choice {
        choose(capable: capable(hosts: hosts),
               offline: offline(hosts: hosts),
               pinned: pinned(defaults: defaults),
               local: home(localMachineID(machines: machines), hosts: hosts),
               withConversation: Set(hosts.filter { $0.lead != nil }.map(\.machineID)),
               activeCounts: activeCounts(hosts: hosts))
    }

    /// This Mac's machine, while its lead can reach the others itself. An
    /// older companion's lead sees only its own machine, so the lead stays
    /// where it was until that companion is updated.
    static func home(_ local: String?, hosts: [FirstMateFleetHost]) -> String? {
        guard let local, hosts.first(where: { $0.machineID == local })?.supportsLeadPeers == true else { return nil }
        return local
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

    /// The Mac's machines that a lead reaches itself, matched by server origin.
    static func reached(by lead: FirstMateLeadSummary?, machines: [HerdrMachine]) -> Set<String> {
        let origins = Set((lead?.peers ?? []).compactMap { HerdrMachine.normalizedOrigin($0.url) })
        guard !origins.isEmpty else { return [] }
        return Set(machines.filter { HerdrMachine.normalizedOrigin($0.urlString).map(origins.contains) ?? false }.map(\.id))
    }

    /// The read-only snapshot a message to the lead carries: every other
    /// machine's active features that its own tools do not reach, or nil when
    /// there are none. A machine this Mac cannot reach is marked offline.
    static func context(hosts: [FirstMateFleetHost], machines: [HerdrMachine] = [], excluding machineID: String) -> FirstMateLeadContext? {
        let reached = reached(by: hosts.first { $0.machineID == machineID }?.lead, machines: machines)
        let others = hosts.filter { $0.machineID != machineID && !reached.contains($0.machineID) }
        let snapshot = others.compactMap { host -> FirstMateLeadContext.Machine? in
            let features: [FirstMateLeadContext.Feature]
            if let entries = host.fleetEntries {
                features = entries.values
                    .filter { $0.archivedAt == nil }
                    .sorted { ($0.activityAt ?? "") > ($1.activityAt ?? "") }
                    .map { entry in
                        FirstMateLeadContext.Feature(
                            label: entry.label,
                            title: entry.title == entry.label ? nil : entry.title,
                            status: entry.hudStatus.rawValue,
                            step: entry.stepIndex.flatMap { FirstMateChatSteps.names.indices.contains($0) ? FirstMateChatSteps.names[$0] : nil },
                            now: entry.now,
                            unread: entry.unread,
                            latest: entry.latestMessage?.text
                        )
                    }
            } else {
                features = host.features.filter { !$0.isArchived }.map { feature in
                    FirstMateLeadContext.Feature(label: feature.title, title: nil,
                                                 status: FirstMateHudStatus.fallback(featureStatus: feature.status).rawValue,
                                                 step: nil, now: nil, unread: false, latest: nil)
                }
            }
            guard !features.isEmpty else { return nil }
            return .init(name: host.machineName, features: features,
                         offline: host.failedPolls >= offlineAfterFailedPolls ? true : nil)
        }
        return snapshot.isEmpty ? nil : FirstMateLeadContext(machines: snapshot)
    }
}
