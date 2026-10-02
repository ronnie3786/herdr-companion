import Foundation
import Observation

struct WatchersSource: Sendable {
    let machineID: String
    let machineName: String
    let client: any WatchersClient
}
@MainActor @Observable final class WatchersStore {
    private(set) var entries: [WatcherEntry] = []
    private(set) var notices: [String: String] = [:]
    private(set) var enabledMachines: Set<String> = []
    private(set) var unreadCount = 0
    private(set) var loaded = false
    private(set) var refreshing = false
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
        entries = demo ? WatchersDemo.entries : []; notices = [:]; inboxCounts = [:]; enabledMachines = []; unreadCount = 0; loaded = demo; refreshing = false; busy = []; actionRequestIDs = [:]; refreshAgain = false
    }
    func client(for machineID: String) -> (any WatchersClient)? { sources.first { $0.machineID == machineID }?.client }
    func refresh() async {
        guard !demo else { return }
        guard !refreshing else { refreshAgain = true; return }
        let token = generation; let revision = mutationRevision; refreshing = true
        defer {
            if token == generation {
                refreshing = false; loaded = true
                if refreshAgain { refreshAgain = false; Task { await refresh() } }
            }
        }
        await withTaskGroup(of: (String, String, [String: PiJSONValue]?, [String: PiJSONValue]?, String?).self) { group in
            for source in sources { group.addTask {
                do {
                    let capabilities = try await source.client.watchersGet(["capabilities"])
                    guard capabilities.flag("enabled") else { return (source.machineID, source.machineName, nil, nil, "Watchers is off on this machine. Enable HERDR_WATCHERS_ENABLED in its private companion configuration.") }
                    async let list = source.client.watchersGet()
                    async let inbox = source.client.watchersGet(["inbox"], query: [.init(name: "unread", value: "1")])
                    return try await (source.machineID, source.machineName, list, inbox, nil)
                } catch {
                    let message: String
                    if case APIError.server(let status, _) = error, status == 404 || status == 501 { message = "Update this companion to add Watchers (watchers-v1)." }
                    else { message = "Machine unavailable: \(error.localizedDescription)" }
                    return (source.machineID, source.machineName, nil, nil, message)
                }
            } }
            for await (machineID, machineName, list, inbox, failure) in group {
                guard token == generation, revision == mutationRevision, !Task.isCancelled else { group.cancelAll(); continue }
                if let failure { notices[machineID] = "\(machineName): \(failure)"; enabledMachines.remove(machineID); continue }
                notices.removeValue(forKey: machineID); enabledMachines.insert(machineID)
                entries.removeAll { $0.machineID == machineID }
                entries += list?["watchers"]?.arrayValue?.compactMap { $0.objectValue.map { WatcherEntry(machineID: machineID, machineName: machineName, watcher: Watcher($0)) } } ?? []
                inboxCounts[machineID] = inbox?["unread_count"].map { if case let .number(value) = $0 { return Int(value) }; return 0 } ?? (inbox?["items"] ?? inbox?["inbox"])?.arrayValue?.count ?? 0
                unreadCount = inboxCounts.values.reduce(0, +)
                entries = Self.ordered(entries)
            }
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
