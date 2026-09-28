import Foundation

/// Which machine's lead First Mate the chat window and the HUD talk to, and
/// what it is told about the others.
///
/// A lead lives on one companion and its tools reach that machine's features,
/// so the Mac picks one: the machine chosen before (in the lead chat's header,
/// or the first automatic choice) while it still has a lead; else the machine
/// with the most active features, so the lead sees most of your work; ties go
/// to this Mac's own companion, then roster order. The choice is remembered
/// once the lead opens, so the conversation stays on one machine. Nil means no
/// machine has a lead yet (older companions), and both surfaces keep their
/// Phase 1 behavior.
enum FirstMateLeadMachine {
    static let preferenceKey = "herdr.mac.firstMate.lead.machine"

    static func choose(capable: [String], saved: String?, local: String?, activeCounts: [String: Int] = [:]) -> String? {
        if let saved, capable.contains(saved) { return saved }
        let most = capable.map { activeCounts[$0] ?? 0 }.max() ?? 0
        let busiest = capable.filter { (activeCounts[$0] ?? 0) == most }
        if let local, busiest.contains(local) { return local }
        return busiest.first
    }

    /// Machines whose companion advertises `first-mate-lead-v1`, in roster order.
    static func capable(hosts: [FirstMateFleetHost]) -> [String] {
        hosts.filter(\.supportsLead).map(\.machineID)
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
    static func current(hosts: [FirstMateFleetHost], machines: [HerdrMachine], defaults: UserDefaults = .standard) -> String? {
        choose(capable: capable(hosts: hosts),
               saved: defaults.string(forKey: preferenceKey),
               local: localMachineID(machines: machines),
               activeCounts: activeCounts(hosts: hosts))
    }

    @MainActor
    static func save(_ machineID: String, defaults: UserDefaults = .standard) {
        defaults.set(machineID, forKey: preferenceKey)
    }

    /// Keeps the lead on `machineID` from now on unless another is chosen.
    /// Called when the lead opens, once every machine with a lead has loaded,
    /// so an early empty list never decides it.
    @MainActor
    static func remember(_ machineID: String, hosts: [FirstMateFleetHost], defaults: UserDefaults = .standard) {
        let capable = capable(hosts: hosts)
        if let saved = defaults.string(forKey: preferenceKey), capable.contains(saved) { return }
        guard hosts.filter({ capable.contains($0.machineID) }).allSatisfy({ $0.lastUpdated != nil }) else { return }
        save(machineID, defaults: defaults)
    }

    /// This Mac's own configured machine, from host evidence read once per
    /// process (the same unique-match rule as a new HUD chat).
    @MainActor
    static func localMachineID(machines: [HerdrMachine]) -> String? {
        HerdrHudNewChatPolicy(hostIdentity: hostIdentity).localMachine(in: machines)?.id
    }

    @MainActor private static let hostIdentity = HerdrHudHostIdentity.current()

    /// The read-only snapshot of every other machine's active features that a
    /// message to the lead carries, or nil when there are none.
    static func context(hosts: [FirstMateFleetHost], excluding machineID: String) -> FirstMateLeadContext? {
        let machines = hosts.filter { $0.machineID != machineID }.compactMap { host -> FirstMateLeadContext.Machine? in
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
            return features.isEmpty ? nil : .init(name: host.machineName, features: features)
        }
        return machines.isEmpty ? nil : FirstMateLeadContext(machines: machines)
    }
}
