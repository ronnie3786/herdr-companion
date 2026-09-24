import Foundation
import Observation

/// Owned by the window shell, so filtering columns or visiting a full screen does
/// not discard an unfinished reply or change that feature's selected tab.
@MainActor @Observable
final class AgentBoardState {
    var filter = AgentBoardFilter.all {
        didSet { if filter != oldValue { resetOrder() } }
    }
    @ObservationIgnored private var columns: [String: AgentBoardColumnState] = [:]
    /// Column order the person is looking at. Polls never shuffle it; a new
    /// feature joins at the end and the order resets on the next visit.
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var capabilityCache: [String: (value: FirstMateCapabilities?, fetchedAt: Date)] = [:]
    @ObservationIgnored private var capabilityRequests: [String: Task<FirstMateCapabilities?, Never>] = [:]
    @ObservationIgnored var capabilityLifetime: TimeInterval = 300

    func column(for entry: DashboardFeatureEntry) -> AgentBoardColumnState {
        if let column = columns[entry.id] { return column }
        let column = AgentBoardColumnState(machineID: entry.machineID, featureID: entry.feature.id)
        columns[entry.id] = column
        return column
    }

    func existingColumn(id: String) -> AgentBoardColumnState? { columns[id] }

    func entries(_ entries: [DashboardFeatureEntry], focusMode: Bool) -> [DashboardFeatureEntry] {
        arranged(entries.filter { entry in
            (!focusMode || entry.needsAttention) && filter.includes(entry)
        })
    }

    /// Keeps the on-screen order stable across polls while still following
    /// additions and removals.
    func arranged(_ entries: [DashboardFeatureEntry]) -> [DashboardFeatureEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = order.compactMap { byID[$0] }
        let placed = Set(result.map(\.id))
        result.append(contentsOf: entries.filter { !placed.contains($0.id) })
        order = result.map(\.id)
        return result
    }

    func resetOrder() { order = [] }

    /// Drops columns for features that left the board, unless the person still
    /// has an unsent reply there.
    func prune(keeping ids: Set<String>) {
        columns = columns.filter { ids.contains($0.key) || $0.value.hasUnsentWork }
    }

    /// Capabilities for one authenticated host, shared by its columns and
    /// refreshed periodically so a companion upgrade takes effect in-session.
    func capabilities(machineID: String, configuration: ServerConfiguration?, generation: Int,
                      client: (any AgentBoardClient)?) async -> FirstMateCapabilities? {
        guard let configuration, let client else { return nil }
        let key = "\(machineID)|\(generation)|\(configuration.baseURL.absoluteString)|\(configuration.token.hashValue)"
        if let cached = capabilityCache[key], Date.now.timeIntervalSince(cached.fetchedAt) < capabilityLifetime {
            return cached.value
        }
        if let request = capabilityRequests[key] { return await request.value }
        let request = Task<FirstMateCapabilities?, Never> {
            do {
                return try await client.fetchFirstMateCapabilities()
            } catch APIError.server(let status, _) where status == 404 || status == 501 {
                // A companion older than capabilities answers definitively.
                return FirstMateCapabilities(ok: true, capabilities: [])
            } catch {
                return nil
            }
        }
        capabilityRequests[key] = request
        let fetched = await request.value
        capabilityRequests[key] = nil
        // A failed check keeps the last answer (a restart does not make a
        // companion forget boards) and is retried soon.
        let value = fetched ?? capabilityCache[key]?.value
        capabilityCache[key] = (value, fetched == nil ? Date.now.addingTimeInterval(20 - capabilityLifetime) : .now)
        return value
    }
}
