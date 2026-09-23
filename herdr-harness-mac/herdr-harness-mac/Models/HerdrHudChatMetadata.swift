import Foundation

/// Aggregates the model and cumulative reported cost of one saved HUD
/// conversation from the run samples the app already polls or loads.
///
/// The accumulator is scoped to the exact machine and thread root. Each
/// accepted run contributes at most once: repeated live samples and history
/// replays replace that run's earlier value instead of adding it again. Older
/// turns are sealed into a running aggregate, so the total survives the
/// 20-exchange in-memory and 10-exchange disk transcript caps.
///
/// Coverage is honest rather than optimistic. A total is only reported when an
/// authoritative source established how many accepted turns the conversation
/// has, every observed turn reported a usable cost, and no turn is missing.
/// Otherwise the cost stays unknown instead of presenting a partial sum as a
/// complete one.
struct HerdrHudChatMetadataAccumulator: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let machineID: String
        let rootRunID: String
    }

    /// One accepted turn's latest known report.
    struct RunSample: Equatable, Sendable {
        let id: String
        let costUSD: Double?
        let modelName: String?

        init(id: String, costUSD: Double?, modelName: String?) {
            self.id = id
            self.costUSD = costUSD
            self.modelName = modelName
        }
    }

    init() {}

    private(set) var identity: Identity?
    /// The accepted-turn count established by the thread or full history.
    /// nil means no authoritative source has proven coverage yet.
    private(set) var knownTurnCount: Int?
    private(set) var latestRunID: String?
    private(set) var latestRunCostUSD: Double?
    private(set) var latestRunModelName: String?
    private(set) var sealedCostUSD: Double = 0
    private(set) var sealedKnownRunCount = 0
    private(set) var sealedUnknownRunCount = 0

    /// How many accepted turns this accumulator has observed.
    var observedRunCount: Int {
        sealedKnownRunCount + sealedUnknownRunCount + (latestRunID == nil ? 0 : 1)
    }

    /// Whether the aggregate covers the whole conversation and every observed
    /// turn reported a usable cost.
    var isComplete: Bool {
        hasEstablishedCoverage
            && latestRunCostUSD != nil
            && sealedUnknownRunCount == 0
            && sealedCostUSD.isFinite
            && sealedCostUSD >= 0
    }

    /// Whether an authoritative source established the full accepted-turn
    /// list. This can hold while a turn's cost is still unknown; the total is
    /// only withheld because a reported component is missing.
    var hasEstablishedCoverage: Bool {
        guard identity != nil, latestRunID != nil else { return false }
        guard let knownTurnCount else { return false }
        return knownTurnCount == observedRunCount
    }

    /// Cumulative reported USD cost for the whole conversation, or nil while
    /// coverage or any turn's report is unknown. Never a partial total.
    var totalCostUSD: Double? {
        guard isComplete, let latestRunCostUSD else { return nil }
        return sealedCostUSD + latestRunCostUSD
    }

    /// The model and cost the bubble presents: the newest accepted turn's model
    /// and the conversation's cumulative reported cost.
    var metadata: HerdrHudSessionMetadata {
        HerdrHudSessionMetadata(
            modelName: latestRunModelName,
            cost: totalCostUSD.flatMap { PiSessionCost(reportedUSD: $0)?.summary }
        )
    }

    func isScoped(to identity: Identity) -> Bool { self.identity == identity }

    mutating func reset() {
        self = HerdrHudChatMetadataAccumulator()
    }

    /// Records an accepted turn observed directly from its submission.
    /// Re-observing the current run replaces its sample without sealing it
    /// again, so duplicate acceptance never double-counts a turn.
    @discardableResult
    mutating func recordAcceptedRun(
        machineID: String,
        rootRunID: String,
        expectedTurnCount: Int,
        sample: RunSample
    ) -> Bool {
        let previous = self
        let targetIdentity = Identity(machineID: machineID, rootRunID: rootRunID)
        if identity != targetIdentity {
            reset()
            identity = targetIdentity
        }
        if latestRunID == sample.id {
            updateLiveRun(sample)
        } else {
            sealLiveRun()
            latestRunID = sample.id
            latestRunCostUSD = Self.validCost(sample.costUSD)
            latestRunModelName = Self.normalizedModelName(sample.modelName)
        }
        knownTurnCount = max(expectedTurnCount, observedRunCount)
        return self != previous
    }

    /// Replaces the current run's sample from polling or completion. The live
    /// run keeps its last known cost and model when a transient response omits
    /// them, and a stale sample for an older run is ignored.
    @discardableResult
    mutating func updateObservedRun(id: String, costUSD: Double?, modelName: String?) -> Bool {
        guard latestRunID == id else { return false }
        let previous = self
        updateLiveRun(RunSample(id: id, costUSD: costUSD, modelName: modelName))
        return self != previous
    }

    /// Replaces aggregate state from an authoritative run list (full paginated
    /// history or a complete restored transcript). Repeated run IDs keep their
    /// last sample and are counted once. `expectedTurnCount` of nil leaves
    /// coverage unproven, which keeps the total unknown.
    @discardableResult
    mutating func reconcile(
        machineID: String,
        rootRunID: String,
        expectedTurnCount: Int?,
        samples: [RunSample]
    ) -> Bool {
        let previous = self
        reset()
        identity = Identity(machineID: machineID, rootRunID: rootRunID)
        var ordered: [RunSample] = []
        var indexByID: [String: Int] = [:]
        for sample in samples {
            let normalized = RunSample(
                id: sample.id,
                costUSD: Self.validCost(sample.costUSD),
                modelName: Self.normalizedModelName(sample.modelName)
            )
            if let index = indexByID[normalized.id] {
                ordered[index] = normalized
            } else {
                indexByID[normalized.id] = ordered.count
                ordered.append(normalized)
            }
        }
        for sample in ordered.dropLast() {
            seal(sample)
        }
        if let latest = ordered.last {
            latestRunID = latest.id
            latestRunCostUSD = latest.costUSD
            latestRunModelName = latest.modelName
        }
        if let expectedTurnCount {
            knownTurnCount = max(expectedTurnCount, observedRunCount)
        }
        return self != previous
    }

    private mutating func updateLiveRun(_ sample: RunSample) {
        if let cost = Self.validCost(sample.costUSD) { latestRunCostUSD = cost }
        if let model = Self.normalizedModelName(sample.modelName) { latestRunModelName = model }
    }

    private mutating func sealLiveRun() {
        guard let latestRunID else { return }
        seal(RunSample(id: latestRunID, costUSD: latestRunCostUSD, modelName: latestRunModelName))
        self.latestRunID = nil
        latestRunCostUSD = nil
        latestRunModelName = nil
    }

    private mutating func seal(_ sample: RunSample) {
        if let cost = Self.validCost(sample.costUSD) {
            sealedCostUSD += cost
            sealedKnownRunCount += 1
        } else {
            sealedUnknownRunCount += 1
        }
    }

    /// A reported sample only counts when it is a real, non-negative number.
    static func validCost(_ cost: Double?) -> Double? {
        guard let cost, cost.isFinite, cost >= 0 else { return nil }
        return cost
    }

    /// The shared sentinel for "no resolved model" is treated as missing, so a
    /// literal `default` label never masquerades as a model name.
    static func normalizedModelName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case "default", "unknown":
            return nil
        default:
            return trimmed
        }
    }
}

extension HerdrHudChatMetadataAccumulator: Codable {
    private enum CodingKeys: String, CodingKey {
        case machineID
        case rootRunID
        case knownTurnCount
        case latestRunID
        case latestRunCostUSD
        case latestRunModelName
        case sealedCostUSD
        case sealedKnownRunCount
        case sealedUnknownRunCount
    }

    /// Lenient decoding keeps existing version-1 caches readable and refuses
    /// to trust malformed local values as a reported total.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let machineID = try container.decodeIfPresent(String.self, forKey: .machineID),
           let rootRunID = try container.decodeIfPresent(String.self, forKey: .rootRunID) {
            identity = Identity(machineID: machineID, rootRunID: rootRunID)
        } else {
            identity = nil
        }
        knownTurnCount = try container.decodeIfPresent(Int.self, forKey: .knownTurnCount)
        latestRunID = try container.decodeIfPresent(String.self, forKey: .latestRunID)
        latestRunCostUSD = Self.validCost(
            try container.decodeIfPresent(Double.self, forKey: .latestRunCostUSD)
        )
        latestRunModelName = Self.normalizedModelName(
            try container.decodeIfPresent(String.self, forKey: .latestRunModelName)
        )
        sealedCostUSD = Self.validCost(
            try container.decodeIfPresent(Double.self, forKey: .sealedCostUSD)
        ) ?? 0
        sealedKnownRunCount = max(0, try container.decodeIfPresent(Int.self, forKey: .sealedKnownRunCount) ?? 0)
        sealedUnknownRunCount = max(0, try container.decodeIfPresent(Int.self, forKey: .sealedUnknownRunCount) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(identity?.machineID, forKey: .machineID)
        try container.encodeIfPresent(identity?.rootRunID, forKey: .rootRunID)
        try container.encodeIfPresent(knownTurnCount, forKey: .knownTurnCount)
        try container.encodeIfPresent(latestRunID, forKey: .latestRunID)
        try container.encodeIfPresent(latestRunCostUSD, forKey: .latestRunCostUSD)
        try container.encodeIfPresent(latestRunModelName, forKey: .latestRunModelName)
        try container.encode(sealedCostUSD, forKey: .sealedCostUSD)
        try container.encode(sealedKnownRunCount, forKey: .sealedKnownRunCount)
        try container.encode(sealedUnknownRunCount, forKey: .sealedUnknownRunCount)
    }
}
