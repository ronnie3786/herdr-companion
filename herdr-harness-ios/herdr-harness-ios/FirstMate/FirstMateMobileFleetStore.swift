import Foundation
import Observation

/// One observed machine and the authenticated client that answers for it.
struct FirstMateMobileFleetSource: Sendable {
    let machine: HerdrMachine
    /// `nil` for the synthetic demo, which has no companion connection.
    let configuration: ServerConfiguration?
    /// `nil` for the synthetic demo, which reads from ``FirstMateStore``'s
    /// built-in sample data.
    let client: (any FirstMateClient)?
    let isDemo: Bool

    init(
        machine: HerdrMachine,
        configuration: ServerConfiguration?,
        client: (any FirstMateClient)?,
        isDemo: Bool = false
    ) {
        self.machine = machine
        self.configuration = configuration
        self.client = client
        self.isDemo = isDemo
    }
}

/// The published state of one machine in the mobile First Mate fleet.
///
/// The fleet deliberately mirrors the fields the list surface needs instead of
/// exposing the per-host ``FirstMateStore`` as view state: a host that has
/// never answered, one that answered with an empty list, one that kept cached
/// features through an outage, and one whose companion predates First Mate all
/// need to be distinguishable without treating any of them as another host.
struct FirstMateMobileFleetHost: Identifiable, Equatable, Sendable {
    let machineID: String
    var machineName: String
    var isDemo: Bool
    var features: [FirstMateFeature] = []
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var unsupported = false
    var lastUpdated: Date?
    var archiveSupported = false
    var attachmentsSupported = false
    var contextSupported = false
    var safeModelSettingsSupported = false
    var linksSupported = false
    var feedbackCapability: FirstMateFeedbackCapability = .unknown

    var id: String { machineID }

    /// The host answered successfully and currently has no features at all.
    var isEmpty: Bool { hasLoaded && error == nil && !unsupported && features.isEmpty }

    /// Cached features remain readable while the host is unreachable.
    var isStale: Bool { error != nil && !features.isEmpty }

    /// The host has never produced a list and its last attempt failed.
    var isUnavailable: Bool { hasLoaded && error != nil && !unsupported && features.isEmpty }

    /// The companion is reachable but does not advertise First Mate.
    var isFirstMateUnsupported: Bool { unsupported }
}

/// Owns the mobile First Mate fleet: one ``FirstMateStore`` per stable machine
/// ID, a browsing scope that is distinct from the selected feature target, and
/// the host-qualified rows a combined list renders.
///
/// The store never fetches for itself. It reconciles an injected roster of
/// machines with their authenticated clients, drives each host's existing
/// store, and mirrors that store's published state so the UI can tell loading,
/// empty, stale/offline, and unsupported hosts apart. Mutations always flow
/// through the exact owning store, found by ``store(for:)``, so a feature ID
/// that exists on several machines can never redirect an action.
@MainActor @Observable
final class FirstMateMobileFleetStore {
    /// The list fields mirrored out of one host store after a refresh.
    private struct HostRefreshSnapshot: Sendable {
        let machineID: String
        let features: [FirstMateFeature]
        let isRefreshing: Bool
        let hasLoaded: Bool
        let error: String?
        let unsupported: Bool
        let lastUpdated: Date?
        let archiveSupported: Bool
        let attachmentsSupported: Bool
        let contextSupported: Bool
        let safeModelSettingsSupported: Bool
        let linksSupported: Bool
        let feedbackCapability: FirstMateFeedbackCapability
    }

    /// The exact feature statuses that wait on a human decision, matching the
    /// mobile list's attention-first sections.
    static let waitingStatuses: Set<String> = ["awaiting_direction", "blocked"]

    /// The explicitly chosen browsing scope, preserved across launches.
    private(set) var scope: FirstMateMachineScope
    /// The feature conversation the detail surface shows. This never decides
    /// where a write goes; the target's machine ID does.
    var selectedTarget: FirstMateFeatureTarget?
    var search = ""
    var showArchived = false
    private(set) var hosts: [FirstMateMobileFleetHost] = []
    /// Bumped only when a host's published state or the roster actually
    /// changes, so observers are not invalidated by telemetry-only polls.
    private(set) var contentRevision = 0
    @ObservationIgnored var pollingInterval: Duration = .seconds(10)
    /// The live stores, keyed by stable machine ID. Reconfigured or removed
    /// hosts are retired before they leave this dictionary, so a reference a
    /// view captured earlier can never operate on a replacement host.
    @ObservationIgnored private var stores: [String: FirstMateStore] = [:]
    /// The authenticated connection each store was last reconciled with.
    /// Equality of the identity — not the roster position or the display name
    /// — decides whether a store survives.
    @ObservationIgnored private var identities: [String: FirstMateConnectionIdentity] = [:]
    @ObservationIgnored private let preference: FirstMateScopePreference
    @ObservationIgnored private var lifecycle = 0
    @ObservationIgnored private var refreshGeneration = 0

    init(defaults: UserDefaults = .standard) {
        let preference = FirstMateScopePreference(defaults: defaults)
        self.preference = preference
        scope = preference.load()
    }

    // MARK: - Browsing scope

    /// The machines currently in the roster.
    var availableMachineIDs: [String] { hosts.map(\.machineID) }

    /// The persisted choice narrowed to the machines that exist right now.
    /// A removed host resolves to All Machines rather than another machine.
    var resolvedScope: FirstMateMachineScope {
        FirstMateMachineScope.resolved(scope, availableMachineIDs: availableMachineIDs)
    }

    /// Remembers an explicit scope choice, including an explicit All Machines,
    /// under the versioned preference key.
    func selectScope(_ scope: FirstMateMachineScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        preference.save(scope)
    }

    /// Applies a Show Archived choice to every host store immediately. The
    /// next ``refresh(lifecycle:)`` fetches the matching server scope, and
    /// ``visibleRows`` filters consistently in the meantime.
    func setShowArchived(_ value: Bool) {
        guard showArchived != value else { return }
        showArchived = value
        for store in stores.values { store.showArchived = value }
    }

    // MARK: - Visible rows

    /// The hosts the current scope shows, in roster order.
    var visibleHosts: [FirstMateMobileFleetHost] {
        let scope = resolvedScope
        return hosts.filter { scope.includes(machineID: $0.machineID) }
    }

    /// Search and Show Archived applied consistently across every visible
    /// host, with the combined view's machine label attached to each row.
    ///
    /// The rows stay grouped by roster order and then by each host's existing
    /// order, so no presentation choice reorders machines implicitly.
    var visibleRows: [FirstMateMobileFleetFeature] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = resolvedScope
        return hosts.flatMap { host -> [FirstMateMobileFleetFeature] in
            guard scope.includes(machineID: host.machineID) else { return [] }
            return host.features.compactMap { feature in
                guard showArchived || !feature.isArchived else { return nil }
                guard query.isEmpty || Self.matches(query, feature: feature, machineName: host.machineName) else { return nil }
                return FirstMateMobileFleetFeature(
                    target: FirstMateFeatureTarget(machineID: host.machineID, featureID: feature.id),
                    machineName: host.machineName,
                    feature: feature
                )
            }
        }
    }

    /// Active rows that wait on a human decision, across visible hosts.
    var waitingRows: [FirstMateMobileFleetFeature] {
        visibleRows.filter { !$0.feature.isArchived && Self.needsHumanDecision(status: $0.feature.status) }
    }

    /// Active rows that do not wait on a human decision, across visible hosts.
    var otherActiveRows: [FirstMateMobileFleetFeature] {
        visibleRows.filter { !$0.feature.isArchived && !Self.needsHumanDecision(status: $0.feature.status) }
    }

    /// Archived rows, across visible hosts. Empty unless Show Archived is on.
    var archivedRows: [FirstMateMobileFleetFeature] {
        visibleRows.filter(\.feature.isArchived)
    }

    /// The number of distinct machine-plus-feature identities waiting on a
    /// human decision across the whole roster.
    ///
    /// Counted from unfiltered hosts so neither search nor the selected scope
    /// hides outstanding attention. Duplicate feature IDs on different
    /// machines count separately; duplicates for one machine count once.
    var attentionCount: Int {
        var waiting = Set<FirstMateFeatureTarget>()
        for host in hosts {
            for feature in host.features
            where !feature.isArchived && Self.needsHumanDecision(status: feature.status) {
                waiting.insert(FirstMateFeatureTarget(machineID: host.machineID, featureID: feature.id))
            }
        }
        return waiting.count
    }

    // MARK: - Exact-owner lookup

    /// The store that owns `target`'s machine. Never another machine.
    func store(for target: FirstMateFeatureTarget) -> FirstMateStore? {
        stores[target.machineID]
    }

    func store(forMachineID machineID: String) -> FirstMateStore? {
        stores[machineID]
    }

    func host(for target: FirstMateFeatureTarget) -> FirstMateMobileFleetHost? {
        hosts.first { $0.machineID == target.machineID }
    }

    /// The feature behind a composite target, preferring the published host
    /// list and falling back to the owning store's full cache.
    func feature(for target: FirstMateFeatureTarget) -> FirstMateFeature? {
        if let feature = hosts.first(where: { $0.machineID == target.machineID })?
            .features.first(where: { $0.id == target.featureID }) {
            return feature
        }
        return stores[target.machineID]?.features.first { $0.id == target.featureID }
    }

    /// The store owning the currently selected feature conversation.
    var selectedStore: FirstMateStore? {
        guard let selectedTarget else { return nil }
        return stores[selectedTarget.machineID]
    }

    var selectedFeature: FirstMateFeature? {
        guard let selectedTarget else { return nil }
        return feature(for: selectedTarget)
    }

    /// Records the exact owner of a feature conversation without changing the
    /// browsing scope. A target for a machine that is not in the roster is
    /// ignored: it is never redirected to a different host.
    func selectTarget(_ target: FirstMateFeatureTarget?) {
        guard let target else {
            selectedTarget = nil
            return
        }
        guard stores[target.machineID] != nil else { return }
        selectedTarget = target
    }

    /// Opens a feature on its owning store while preserving the browsing
    /// scope. Returns false when the owning machine is not configured.
    @discardableResult
    func open(_ target: FirstMateFeatureTarget) -> Bool {
        guard let store = stores[target.machineID] else { return false }
        selectedTarget = target
        store.select(target.featureID)
        return true
    }

    // MARK: - Roster reconciliation

    /// Installs the observed roster and returns the lifecycle token that
    /// ``refresh(lifecycle:)`` and ``deactivate(lifecycle:)`` require.
    ///
    /// Hosts are reconciled by stable machine ID and authenticated connection
    /// identity, never by roster position or display name. An unchanged host
    /// keeps its store — and every draft and selection inside it — while its
    /// label follows the current roster. Removed hosts and hosts whose
    /// connection was reconfigured have their stores retired first, and every
    /// activation invalidates older refreshes, so a delayed result can never
    /// repopulate a stale connection.
    @discardableResult
    func activate(sources: [FirstMateMobileFleetSource], connectionGeneration: Int) -> Int {
        lifecycle &+= 1
        refreshGeneration &+= 1
        let previousHosts = hosts
        let previousStores = stores
        let previousIdentities = identities

        var nextStores: [String: FirstMateStore] = [:]
        var nextIdentities: [String: FirstMateConnectionIdentity] = [:]
        var nextHosts: [FirstMateMobileFleetHost] = []
        var seenMachineIDs: Set<String> = []
        var retiredMachineIDs: Set<String> = []

        for source in sources {
            let machineID = source.machine.id
            guard seenMachineIDs.insert(machineID).inserted else { continue }
            let identity = FirstMateConnectionIdentity(
                configuration: source.configuration,
                generation: connectionGeneration,
                isDemo: source.isDemo
            )
            let previousStore = previousStores[machineID]
            let store: FirstMateStore
            if let previousStore, previousIdentities[machineID] == identity {
                store = previousStore
            } else {
                // Retire the old store before the replacement is visible so a
                // captured reference can never act on the new connection.
                previousStore?.configure(client: nil, demo: false)
                store = FirstMateStore()
                store.showArchived = showArchived
                store.configure(client: source.client, demo: source.isDemo)
                retiredMachineIDs.insert(machineID)
            }
            nextStores[machineID] = store
            nextIdentities[machineID] = identity

            if let cached = previousHosts.first(where: { $0.machineID == machineID }),
               previousStores[machineID] === store {
                var retained = cached
                retained.machineName = source.machine.name
                retained.isDemo = source.isDemo
                // Any in-flight refresh belongs to an older lifecycle and will
                // be rejected, so it must not leave a spinner running.
                retained.isLoading = false
                nextHosts.append(retained)
            } else {
                nextHosts.append(FirstMateMobileFleetHost(
                    machineID: machineID,
                    machineName: source.machine.name,
                    isDemo: source.isDemo
                ))
            }
        }

        // Retire every store that vanished from the roster.
        for (machineID, store) in previousStores where nextStores[machineID] == nil {
            store.configure(client: nil, demo: false)
            retiredMachineIDs.insert(machineID)
        }

        stores = nextStores
        identities = nextIdentities
        if hosts != nextHosts {
            hosts = nextHosts
            contentRevision &+= 1
        }
        if let target = selectedTarget, retiredMachineIDs.contains(target.machineID) {
            selectedTarget = nil
        }
        return lifecycle
    }

    /// Stops observation for a lifecycle without discarding any host store.
    /// Drafts and cached lists survive leaving the screen; only the spinner
    /// state is released.
    func deactivate(lifecycle expectedLifecycle: Int? = nil) {
        if let expectedLifecycle, expectedLifecycle != lifecycle { return }
        lifecycle &+= 1
        refreshGeneration &+= 1
        for index in hosts.indices where hosts[index].isLoading {
            hosts[index].isLoading = false
        }
    }

    /// Retires every store immediately. Used when the whole app connection is
    /// replaced, so no captured store reference can operate afterwards.
    func retireAll() {
        lifecycle &+= 1
        refreshGeneration &+= 1
        for store in stores.values { store.configure(client: nil, demo: false) }
        stores = [:]
        identities = [:]
        if !hosts.isEmpty {
            hosts = []
            contentRevision &+= 1
        }
        selectedTarget = nil
    }

    // MARK: - Refresh

    /// Refreshes the current lifecycle's hosts.
    func refresh() async {
        await refresh(lifecycle: lifecycle)
    }

    /// Refreshes every host independently of the others.
    ///
    /// Each host store is driven in its own child task, so one slow or offline
    /// companion cannot block a healthy host's result from being published.
    func refresh(lifecycle expectedLifecycle: Int) async {
        guard !Task.isCancelled, expectedLifecycle == lifecycle else { return }
        refreshGeneration &+= 1
        let token = refreshGeneration
        let activeStores = stores
        let expectedConnections = identities

        // Only a host that has never answered shows as loading. A background
        // poll of a loaded host changes nothing observable until its data
        // changes.
        for index in hosts.indices {
            let host = hosts[index]
            guard activeStores[host.machineID] != nil else { continue }
            let shouldShowLoading = host.lastUpdated == nil && host.error == nil && !host.unsupported
            if host.isLoading != shouldShowLoading {
                hosts[index].isLoading = shouldShowLoading
                contentRevision &+= 1
            }
        }

        for store in activeStores.values where store.showArchived != showArchived {
            store.showArchived = showArchived
        }

        await withTaskGroup(of: HostRefreshSnapshot.self) { group in
            for (machineID, store) in activeStores {
                group.addTask {
                    await Self.refreshSnapshot(of: store, machineID: machineID)
                }
            }
            for await snapshot in group {
                guard !Task.isCancelled,
                      expectedLifecycle == lifecycle,
                      token == refreshGeneration,
                      activeStores[snapshot.machineID] === stores[snapshot.machineID],
                      identities[snapshot.machineID] == expectedConnections[snapshot.machineID],
                      let index = hosts.firstIndex(where: { $0.machineID == snapshot.machineID })
                else { continue }
                apply(snapshot, at: index)
            }
        }
    }

    /// Activates the roster, refreshes it immediately, and then refreshes on
    /// ``pollingInterval`` until this task is cancelled or a newer activation
    /// supersedes the roster.
    ///
    /// The deferred deactivation is lifecycle-scoped, so a superseded observer
    /// can never tear down a newer roster or apply a delayed result. Stores are
    /// never discarded here: cancelling observation only stops polling.
    func observe(sources: [FirstMateMobileFleetSource], connectionGeneration: Int) async {
        guard !Task.isCancelled else { return }
        let expectedLifecycle = activate(sources: sources, connectionGeneration: connectionGeneration)
        defer { deactivate(lifecycle: expectedLifecycle) }
        guard !sources.isEmpty else { return }
        await refresh(lifecycle: expectedLifecycle)
        while isObserving(expectedLifecycle) {
            do {
                try await Task.sleep(for: pollingInterval)
            } catch {
                return
            }
            guard isObserving(expectedLifecycle) else { return }
            await refresh(lifecycle: expectedLifecycle)
        }
    }

    private func isObserving(_ expectedLifecycle: Int) -> Bool {
        !Task.isCancelled && expectedLifecycle == lifecycle
    }

    // MARK: - Mirroring

    @MainActor
    private static func refreshSnapshot(of store: FirstMateStore, machineID: String) async -> HostRefreshSnapshot {
        await store.refresh()
        return snapshot(from: store, machineID: machineID)
    }

    private static func snapshot(from store: FirstMateStore, machineID: String) -> HostRefreshSnapshot {
        HostRefreshSnapshot(
            machineID: machineID,
            features: store.features,
            isRefreshing: store.isRefreshing,
            hasLoaded: store.hasLoaded,
            error: store.error,
            unsupported: store.unsupported,
            lastUpdated: store.lastUpdated,
            archiveSupported: store.archiveSupported,
            attachmentsSupported: store.attachmentsSupported,
            contextSupported: store.contextSupported,
            safeModelSettingsSupported: store.safeModelSettingsSupported,
            linksSupported: store.linksSupported,
            feedbackCapability: store.feedbackCapability
        )
    }

    private func apply(_ snapshot: HostRefreshSnapshot, at index: Int) {
        var host = hosts[index]
        let needsFreshLastSeen = host.lastUpdated == nil || host.error != nil || host.unsupported
        if !Self.samePublishedFeatures(host.features, snapshot.features) {
            host.features = snapshot.features
        }
        host.isLoading = snapshot.isRefreshing && !snapshot.hasLoaded
        host.hasLoaded = snapshot.hasLoaded
        host.error = snapshot.error
        host.unsupported = snapshot.unsupported
        host.archiveSupported = snapshot.archiveSupported
        host.attachmentsSupported = snapshot.attachmentsSupported
        host.contextSupported = snapshot.contextSupported
        host.safeModelSettingsSupported = snapshot.safeModelSettingsSupported
        host.linksSupported = snapshot.linksSupported
        host.feedbackCapability = snapshot.feedbackCapability
        // "Last seen" only moves when a host newly succeeds or recovers. A
        // steady stream of successful polls must not republish every interval.
        if snapshot.error == nil, snapshot.hasLoaded, needsFreshLastSeen {
            host.lastUpdated = snapshot.lastUpdated ?? .now
        }
        if host != hosts[index] {
            hosts[index] = host
            contentRevision &+= 1
        }
    }

    private static func matches(_ query: String, feature: FirstMateFeature, machineName: String) -> Bool {
        feature.title.localizedCaseInsensitiveContains(query)
            || feature.goal.localizedCaseInsensitiveContains(query)
            || (feature.workItemID?.localizedCaseInsensitiveContains(query) ?? false)
            || machineName.localizedCaseInsensitiveContains(query)
    }

    static func needsHumanDecision(status: String) -> Bool {
        waitingStatuses.contains(status)
    }

    /// Pi telemetry refreshes each feature's usage, context estimate, and
    /// `updated_at` on nearly every poll while agents work, but none of the
    /// list's published content depends on them. Treating those alone as a
    /// change keeps observers from being invalidated every interval.
    static func samePublishedFeatures(_ lhs: [FirstMateFeature], _ rhs: [FirstMateFeature]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard left != right else { return true }
            var a = left, b = right
            a.usage = nil; b.usage = nil
            a.coordinatorContext = nil; b.coordinatorContext = nil
            if a.dashboardSummary?.activityAt != nil, b.dashboardSummary?.activityAt != nil { a.updatedAt = b.updatedAt }
            return a == b
        }
    }
}
