import Foundation
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

/// A scripted First Mate companion for the chat window's model tests. Every
/// answer can be swapped between calls; calls are counted.
final class SyntheticChatFleetClient: FirstMateClient, @unchecked Sendable {
    typealias ReadHandler = @Sendable (_ featureID: String, _ messageID: String) async throws -> FirstMateReadResponse

    private let lock = NSLock()
    private var _capabilities: Result<[String], APIError>
    private var _features: Result<[FirstMateFeature], APIError>
    private var _fleet: Result<[FirstMateFleetEntry], APIError>
    private var _read: ReadHandler
    private var _snapshots: [String: FirstMateSnapshot] = [:]
    private var _capabilityCalls = 0
    private var _featureListCalls = 0
    private var _featureCalls = 0
    private var _fleetCalls = 0
    private var _reads: [(featureID: String, messageID: String)] = []
    private var _hudUpdates: [(featureID: String, label: String?, emoji: String?)] = []
    private var _hudFailure: APIError?
    /// The lead summary GET and POST return (nil: no lead yet).
    private var _lead: FirstMateLeadSummary?
    private var _leadCalls = 0
    private var _ensureCalls = 0
    private var _sent: [(featureID: String, text: String)] = []
    private var _sentContexts: [FirstMateLeadContext] = []
    private var _sentRequestIDs: [String] = []
    private var _beforeSend: (@Sendable () async throws -> Void)?
    private var _beforeEnsure: (@Sendable () async throws -> Void)?
    private var _beforeFeatureList: (@Sendable () async throws -> Void)?
    typealias PresentationHandler = @Sendable (String, FirstMateReadView, String?, String?) async throws -> FirstMatePresentationResponse
    private var _presentation: PresentationHandler?
    var presentation: PresentationHandler? {
        get { lock.withLock { _presentation } }
        set { lock.withLock { _presentation = newValue } }
    }
    func fetchFirstMatePresentation(_ id: String, view: FirstMateReadView, before: String?, ifVersion: String?) async throws -> FirstMatePresentationResponse {
        if let handler = presentation { return try await handler(id, view, before, ifVersion) }
        return .init(snapshot: try await fetchFirstMateFeature(id))
    }
    private var _beforeFeature: (@Sendable (String) async throws -> Void)?

    var beforeFeatureList: (@Sendable () async throws -> Void)? {
        get { lock.withLock { _beforeFeatureList } }
        set { lock.withLock { _beforeFeatureList = newValue } }
    }
    var beforeFeature: (@Sendable (String) async throws -> Void)? {
        get { lock.withLock { _beforeFeature } }
        set { lock.withLock { _beforeFeature = newValue } }
    }

    var sentRequestIDs: [String] { lock.withLock { _sentRequestIDs } }
    var beforeSend: (@Sendable () async throws -> Void)? {
        get { lock.withLock { _beforeSend } }
        set { lock.withLock { _beforeSend = newValue } }
    }
    var beforeEnsure: (@Sendable () async throws -> Void)? {
        get { lock.withLock { _beforeEnsure } }
        set { lock.withLock { _beforeEnsure = newValue } }
    }

    init(
        capabilities: Result<[String], APIError> = .success(["first-mate-v1", "first-mate-fleet-v1"]),
        features: [FirstMateFeature] = [],
        fleet: [FirstMateFleetEntry] = [],
        read: ReadHandler? = nil
    ) {
        _capabilities = capabilities
        _features = .success(features)
        _fleet = .success(fleet)
        _read = read ?? { featureID, messageID in
            FirstMateReadResponse(featureID: featureID, readThroughMessageID: messageID, unread: false)
        }
    }

    var capabilities: Result<[String], APIError> {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }
    var features: Result<[FirstMateFeature], APIError> {
        get { lock.withLock { _features } }
        set { lock.withLock { _features = newValue } }
    }
    var fleet: Result<[FirstMateFleetEntry], APIError> {
        get { lock.withLock { _fleet } }
        set { lock.withLock { _fleet = newValue } }
    }
    var read: ReadHandler {
        get { lock.withLock { _read } }
        set { lock.withLock { _read = newValue } }
    }
    var snapshots: [String: FirstMateSnapshot] {
        get { lock.withLock { _snapshots } }
        set { lock.withLock { _snapshots = newValue } }
    }
    var lead: FirstMateLeadSummary? {
        get { lock.withLock { _lead } }
        set { lock.withLock { _lead = newValue } }
    }
    var leadCalls: Int { lock.withLock { _leadCalls } }
    var ensureCalls: Int { lock.withLock { _ensureCalls } }
    var sent: [(featureID: String, text: String)] { lock.withLock { _sent } }
    var sentContexts: [FirstMateLeadContext] { lock.withLock { _sentContexts } }
    var capabilityCalls: Int { lock.withLock { _capabilityCalls } }
    var featureListCalls: Int { lock.withLock { _featureListCalls } }
    var featureCalls: Int { lock.withLock { _featureCalls } }
    var fleetCalls: Int { lock.withLock { _fleetCalls } }
    var reads: [(featureID: String, messageID: String)] { lock.withLock { _reads } }
    var hudUpdates: [(featureID: String, label: String?, emoji: String?)] { lock.withLock { _hudUpdates } }
    var hudFailure: APIError? {
        get { lock.withLock { _hudFailure } }
        set { lock.withLock { _hudFailure = newValue } }
    }
    /// Runs before the capability probe answers (tests that check overlap).
    private var _beforeCapabilities: (@Sendable () async -> Void)?
    var beforeCapabilities: (@Sendable () async -> Void)? {
        get { lock.withLock { _beforeCapabilities } }
        set { lock.withLock { _beforeCapabilities = newValue } }
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        let (result, before) = lock.withLock { _capabilityCalls += 1; return (_capabilities, _beforeCapabilities) }
        await before?()
        return FirstMateCapabilities(ok: true, capabilities: try result.get())
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        let (result, before) = lock.withLock { _featureListCalls += 1; return (_features, _beforeFeatureList) }
        try await before?()
        return FirstMateFeatureList(ok: true, features: try result.get())
    }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        let result = lock.withLock { _fleetCalls += 1; return _fleet }
        return FirstMateFleetResponse(features: try result.get())
    }
    func updateFirstMateHud(featureID: String, label: String?, emoji: String?) async throws -> FirstMateFleetEntry {
        try lock.withLock {
            _hudUpdates.append((featureID, label, emoji))
            if let _hudFailure { throw _hudFailure }
            guard case .success(let entries) = _fleet,
                  var entry = entries.first(where: { $0.featureID == featureID }) else { throw APIError.invalidResponse }
            if let label {
                entry.label = label.isEmpty ? FirstMateFleetEntry.serverDefaultLabel(title: entry.title) : label
                entry.labelSource = label.isEmpty ? "default" : "user"
            }
            if let emoji {
                entry.emoji = emoji.isEmpty ? FirstMateDefaultEmoji.emoji(for: featureID) : emoji
                entry.emojiSource = emoji.isEmpty ? "default" : "user"
            }
            _fleet = .success(entries.map { $0.featureID == featureID ? entry : $0 })
            return entry
        }
    }
    func markFirstMateRead(featureID: String, throughMessageID: String) async throws -> FirstMateReadResponse {
        let handler = lock.withLock { _reads.append((featureID, throughMessageID)); return _read }
        return try await handler(featureID, throughMessageID)
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        let (snapshot, before) = lock.withLock { _featureCalls += 1; return (_snapshots[id], _beforeFeature) }
        try await before?(id)
        if let snapshot { return snapshot }
        if case .success(let features) = features, let feature = features.first(where: { $0.id == id }) {
            return FirstMateSnapshot(feature: feature)
        }
        throw APIError.invalidResponse
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        let snapshot = lock.withLock { () -> FirstMateSnapshot? in
            _sent.append((featureID, text))
            _sentRequestIDs.append(requestID)
            return _snapshots[featureID]
        }
        try await beforeSend?()
        guard let snapshot else { throw APIError.invalidResponse }
        return snapshot
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String,
                              context: FirstMateLeadContext) async throws -> FirstMateSnapshot {
        lock.withLock { _sentContexts.append(context) }
        return try await sendFirstMateMessage(featureID: featureID, text: text, requestID: requestID)
    }
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse {
        let lead = lock.withLock { _leadCalls += 1; return _lead }
        return FirstMateLeadResponse(ok: true, lead: lead)
    }
    func ensureFirstMateLead(requestID: String) async throws -> FirstMateLeadResponse {
        let lead = lock.withLock { _ensureCalls += 1; return _lead }
        try await beforeEnsure?()
        guard let lead else { throw APIError.invalidResponse }
        return FirstMateLeadResponse(ok: true, lead: lead)
    }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}

/// Holds one asynchronous answer until the test releases it.
actor ChatTestGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var arrived = false

    func wait() async {
        arrived = true
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

enum ChatFixtures {
    static func feature(
        _ id: String,
        title: String? = nil,
        status: String = "running",
        archived: Bool = false,
        activityAt: String? = nil,
        latestMessage: String? = nil
    ) -> FirstMateFeature {
        var feature = FirstMateDemo.newFeature(title: title ?? "Synthetic \(id)", goal: "A synthetic goal", cwd: "/tmp/synthetic", id: id).feature
        feature.status = status
        if archived { feature.archivedAt = "2030-01-01T00:00:00Z" }
        if activityAt != nil || latestMessage != nil {
            feature.dashboardSummary = FirstMateDashboardSummary(
                currentStageTitle: nil, currentStageIndex: nil, stageCount: 0, latestMessage: latestMessage,
                latestMessageAt: activityAt, needsUser: false, needsUserPrompt: nil, assignmentCount: 0,
                runningAssignmentCount: 0, activityAt: activityAt
            )
        }
        return feature
    }

    static func entry(
        _ id: String,
        hud: FirstMateHudStatus,
        unread: Bool = true,
        latestFirstMate: String? = "fmm_\(UUID().uuidString.prefix(8))",
        latest: FirstMateFleetLatestMessage? = nil,
        activityAt: String? = "2030-01-01T10:00:00Z",
        archived: Bool = false,
        step: Int? = nil
    ) -> FirstMateFleetEntry {
        let status: String = switch hud {
        case .blocked: "blocked"
        case .turn, .ready: "awaiting_direction"
        case .working: "running"
        case .idle, .unknown: "ready"
        case .done: "completed"
        }
        return FirstMateFleetEntry(
            featureID: id, title: "Synthetic \(id)", status: status, hudStatus: hud, stepIndex: step,
            latestMessage: latest ?? latestFirstMate.map { .init(id: $0, role: "assistant", text: "Update for \(id)", createdAt: activityAt) },
            latestFirstMateMessageID: latestFirstMate, unread: unread, activityAt: activityAt,
            archivedAt: archived ? "2030-01-01T00:00:00Z" : nil
        )
    }

    static func host(
        _ id: String,
        name: String? = nil,
        features: [FirstMateFeature] = [],
        entries: [FirstMateFleetEntry]? = nil,
        error: String? = nil
    ) -> FirstMateFleetHost {
        FirstMateFleetHost(
            machineID: id, machineName: name ?? "\(id.capitalized) Mac", features: features, isLoading: false,
            error: error, unsupported: false, lastUpdated: Date(timeIntervalSince1970: 1_900_000_000),
            supportsFleet: entries != nil,
            fleetEntries: entries.map { Dictionary($0.map { ($0.featureID, $0) }, uniquingKeysWith: { first, _ in first }) }
        )
    }

    static func machine(_ id: String) -> HerdrMachine {
        HerdrMachine(id: id, name: "\(id.capitalized) Mac", urlString: "https://\(id).example.invalid")
    }

    static func source(_ id: String, client: SyntheticChatFleetClient, token: String = "token") -> FirstMateFleetSource {
        let machine = machine(id)
        return FirstMateFleetSource(
            machine: machine,
            configuration: ServerConfiguration(urlString: machine.urlString, token: "\(id)-\(token)")!,
            client: client
        )
    }



    /// Fails instead of hanging when a condition is not met in time.
    @MainActor
    static func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw ChatTestTimeout(description: description) }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    static func conversation(
        _ title: String,
        hud: FirstMateHudStatus,
        step: Int? = nil,
        featureStatus: String = "running",
        activityAt: Date? = nil,
        unread: Bool = false
    ) -> FirstMateConversation {
        FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: "local", featureID: title), machineID: "local", machineName: "Local Mac",
            featureID: title, title: title, label: title, isUserNamed: false, emoji: "🧪", isUserEmoji: false,
            hudStatus: hud, featureStatus: featureStatus,
            stepIndex: step, stepFraction: nil, now: nil, previewText: "", previewIsFromUser: false,
            isWorkingOnReply: false, activityAt: activityAt, latestFirstMateMessageID: nil, isUnread: unread, isArchived: false
        )
    }
}

struct ChatTestTimeout: Error, CustomStringConvertible {
    let description: String
}
