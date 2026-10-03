import Foundation
import Observation

struct WatchersSource: Sendable {
    let machineID: String
    let machineName: String
    let client: any WatchersClient
}
/// Whether a machine can host watchers right now. Only `unreachable` is a
/// problem worth a banner; the rest is setup the Runs on picker explains.
enum WatcherMachineState: Equatable, Sendable {
    case checking
    case on(supervised: Bool)
    /// `canTurnOn`: the companion accepts the app's setting. `lockedOff`: its
    /// configuration pins HERDR_WATCHERS_ENABLED to 0.
    case off(canTurnOn: Bool, lockedOff: Bool)
    case needsUpdate
    case unreachable(String)

    var isOn: Bool { if case .on = self { true } else { false } }
    /// A short word for the Runs on menu.
    var label: String {
        switch self {
        case .checking: "Checking…"
        case .on: "On"
        case .off: "Watchers off"
        case .needsUpdate: "Needs update"
        case .unreachable: "Offline"
        }
    }
    init(capabilities: [String: PiJSONValue]) {
        if capabilities.flag("enabled") { self = .on(supervised: capabilities.flag("supervised")); return }
        let settings = capabilities["settings"]?.objectValue
        self = .off(canTurnOn: settings?.flag("changeable") ?? false, lockedOff: settings.map { !$0.flag("changeable") } ?? false)
    }
}
@MainActor @Observable final class WatchersStore {
    private(set) var entries: [WatcherEntry] = []
    private(set) var notices: [String: String] = [:]
    private(set) var enabledMachines: Set<String> = []
    private(set) var machineStates: [String: WatcherMachineState] = [:]
    /// Machines whose setting is being changed, and the last failure per machine.
    private(set) var changingMachines: Set<String> = []
    private(set) var settingErrors: [String: String] = [:]
    private(set) var unreadCount = 0
    private(set) var loaded = false
    private(set) var refreshing = false
    @ObservationIgnored private(set) var lastSuccessfulRefreshAt: Date?
    var error: String?
    var busy: Set<String> = []
    private(set) var demo = false
    @ObservationIgnored private var identity: AnyHashable?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var mutationRevision = 0
    @ObservationIgnored private(set) var sources: [WatchersSource] = []
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var actionRequestIDs: [String: String] = [:]
    @ObservationIgnored private var inboxCounts: [String: Int] = [:]
    /// Machines seen hosting watchers this session; only their outages earn a banner.
    @ObservationIgnored private var seenOn: Set<String> = []

    var pollingInterval: Duration { entries.contains { $0.watcher.live != nil } ? .seconds(5) : .seconds(30) }
    var nextToWake: WatcherEntry? { Self.nextToWake(entries) }
    static func nextToWake(_ entries: [WatcherEntry]) -> WatcherEntry? {
        entries.filter { $0.watcher.state == "active" && $0.watcher.live == nil && $0.watcher.nextFire != nil }.min { $0.watcher.nextFire! < $1.watcher.nextFire! }
    }
    static func ordered(_ entries: [WatcherEntry]) -> [WatcherEntry] {
        func rank(_ w: Watcher) -> Int { w.live != nil ? 0 : w.resting ? 4 : w.attention != nil ? 1 : w.state == "draft" ? 3 : 2 }
        return entries.sorted { a, b in
            if rank(a.watcher) != rank(b.watcher) { return rank(a.watcher) < rank(b.watcher) }
            if a.watcher.nextFire != b.watcher.nextFire { return (a.watcher.nextFire ?? .distantFuture) < (b.watcher.nextFire ?? .distantFuture) }
            return a.watcher.name.localizedStandardCompare(b.watcher.name) == .orderedAscending
        }
    }
    func configure(_ sources: [WatchersSource], identity: AnyHashable, demo: Bool) {
        guard self.identity != identity else { return }
        generation &+= 1; self.identity = identity; self.sources = sources; self.demo = demo
        lastSuccessfulRefreshAt = nil
        entries = demo ? WatchersDemo.entries : []; notices = [:]; inboxCounts = [:]; enabledMachines = []; unreadCount = 0; loaded = demo; refreshing = false; busy = []; actionRequestIDs = [:]; refreshAgain = false
        machineStates = Dictionary(sources.map { ($0.machineID, demo ? WatcherMachineState.on(supervised: true) : .checking) }, uniquingKeysWith: { first, _ in first }); changingMachines = []; settingErrors = [:]; seenOn = []
    }
    func client(for machineID: String) -> (any WatchersClient)? { sources.first { $0.machineID == machineID }?.client }
    func refresh() async {
        guard !demo else { return }
        guard !refreshing else { refreshAgain = true; return }
        let token = generation; let revision = mutationRevision; refreshing = true
        var successfulHosts = 0
        defer {
            if token == generation {
                refreshing = false; loaded = true
                if refreshAgain { refreshAgain = false; Task { await refresh() } }
            }
        }
        await withTaskGroup(of: (String, String, WatcherMachineState, [String: PiJSONValue]?, [String: PiJSONValue]?).self) { group in
            for source in sources { group.addTask {
                do {
                    let state = WatcherMachineState(capabilities: try await source.client.watchersGet(["capabilities"]))
                    guard state.isOn else { return (source.machineID, source.machineName, state, nil, nil) }
                    async let list = source.client.watchersGet()
                    async let inbox = source.client.watchersGet(["inbox"], query: [.init(name: "unread", value: "1")])
                    return try await (source.machineID, source.machineName, state, list, inbox)
                } catch {
                    if case APIError.server(let status, _) = error, status == 404 || status == 501 { return (source.machineID, source.machineName, .needsUpdate, nil, nil) }
                    return (source.machineID, source.machineName, .unreachable(error.localizedDescription), nil, nil)
                }
            } }
            for await (machineID, machineName, state, list, inbox) in group {
                guard token == generation, revision == mutationRevision, !Task.isCancelled else { group.cancelAll(); continue }
                switch state {
                case .on, .off: successfulHosts += 1
                case .checking, .needsUpdate, .unreachable: break
                }
                machineStates[machineID] = state
                guard state.isOn else {
                    enabledMachines.remove(machineID); inboxCounts[machineID] = nil; unreadCount = inboxCounts.values.reduce(0, +)
                    if case .unreachable = state, seenOn.contains(machineID) { notices[machineID] = "\(machineName) isn’t reachable right now, so its watchers aren’t shown. They keep running on that machine." }
                    else { notices.removeValue(forKey: machineID) }
                    if case .off = state { entries.removeAll { $0.machineID == machineID } }
                    continue
                }
                notices.removeValue(forKey: machineID); enabledMachines.insert(machineID); seenOn.insert(machineID)
                entries.removeAll { $0.machineID == machineID }
                entries += list?["watchers"]?.arrayValue?.compactMap { $0.objectValue.map { WatcherEntry(machineID: machineID, machineName: machineName, watcher: Watcher($0)) } } ?? []
                inboxCounts[machineID] = inbox?["unread_count"].map { if case let .number(value) = $0 { return Int(value) }; return 0 } ?? (inbox?["items"] ?? inbox?["inbox"])?.arrayValue?.count ?? 0
                unreadCount = inboxCounts.values.reduce(0, +)
                entries = Self.ordered(entries)
            }
        }
        if token == generation, revision == mutationRevision, !Task.isCancelled,
           !sources.isEmpty, successfulHosts == sources.count { lastSuccessfulRefreshAt = .now }
    }
    func state(for machineID: String) -> WatcherMachineState { machineStates[machineID] ?? .checking }
    func machineName(for machineID: String) -> String { sources.first { $0.machineID == machineID }?.machineName ?? machineID }
    /// Turns Watchers on or off for one machine through its companion's
    /// setting. The person confirms by clicking; agents cannot reach this path.
    func setWatchersEnabled(_ enabled: Bool, machineID: String) async {
        guard let client = client(for: machineID), changingMachines.insert(machineID).inserted else { return }
        let token = generation
        defer { if token == generation { changingMachines.remove(machineID) } }
        do {
            let response = try await client.watchersMutate(["settings"], body: ["enabled": .bool(enabled), "confirmed_by": .string("user"), "changed_via": .string("mac")])
            guard token == generation else { return }
            settingErrors[machineID] = nil; machineStates[machineID] = WatcherMachineState(capabilities: response)
            mutationRevision &+= 1; await refresh()
        } catch {
            guard token == generation else { return }
            if case APIError.server(let status, _) = error, status == 404 || status == 405 {
                settingErrors[machineID] = "This companion can’t be turned on from the app yet. Update it, or use its configuration."
                machineStates[machineID] = .off(canTurnOn: false, lockedOff: false)
            } else { settingErrors[machineID] = error.localizedDescription }
        }
    }
    func action(_ action: String, entry: WatcherEntry) async {
        guard let client = client(for: entry.machineID), busy.insert(entry.id).inserted else { return }
        let token = generation; mutationRevision &+= 1
        let requestKey = entry.id + ":" + action
        let requestID = actionRequestIDs[requestKey] ?? UUID().uuidString
        actionRequestIDs[requestKey] = requestID
        defer { if token == generation { busy.remove(entry.id) } }
        do {
            if action == "stop", let id = entry.watcher.live?.text("run_id"), !id.isEmpty { _ = try await client.watchersMutate(["runs", id, "stop"], requestID: requestID) }
            else {
                var body: [String: PiJSONValue] = ["action": .string(action)]
                if action == "activate" || action == "resume" { body["confirmed_by"] = .string("user"); body["activated_via"] = .string("mac") }
                _ = try await client.watchersMutate([entry.watcher.id, "actions"], body: body, requestID: requestID)
            }
            guard token == generation else { return }; actionRequestIDs.removeValue(forKey: requestKey); error = nil; await refresh()
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
}
