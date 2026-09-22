import Foundation

/// A point-in-time measurement of the feature's current native coordinator.
/// This is context pressure, not cumulative usage or billing telemetry.
struct FirstMateCoordinatorContext: Codable, Equatable, Sendable {
    /// JSON integers above 2^53 - 1 cannot be represented exactly by all
    /// contract peers and are not credible token measurements.
    private static let maximumJSONSafeInteger = 9_007_199_254_740_991

    enum Status: String, Codable, Sendable {
        case measured
        case unavailable
    }

    var nativeSessionID: String?
    var status: Status
    var tokens: Int?
    var contextWindow: Int?
    var handoffTargetTokens: Int?
    var observedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, tokens
        case nativeSessionID = "native_session_id"
        case contextWindow = "context_window"
        case handoffTargetTokens = "handoff_target_tokens"
        case observedAt = "observed_at"
    }

    init(
        nativeSessionID: String? = nil,
        status: Status,
        tokens: Int? = nil,
        contextWindow: Int? = nil,
        handoffTargetTokens: Int? = nil,
        observedAt: String? = nil
    ) {
        self.nativeSessionID = nativeSessionID
        self.status = status
        self.tokens = tokens.flatMap(Self.validNonnegativeMeasurement)
        self.contextWindow = contextWindow.flatMap(Self.validPositiveMeasurement)
        self.handoffTargetTokens = handoffTargetTokens.flatMap(Self.validPositiveMeasurement)
        self.observedAt = observedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nativeSessionID = try? container.decodeIfPresent(String.self, forKey: .nativeSessionID)
        status = (try? container.decode(Status.self, forKey: .status)) ?? .unavailable

        tokens = (try? container.decode(Int.self, forKey: .tokens)).flatMap(Self.validNonnegativeMeasurement)
        contextWindow = (try? container.decode(Int.self, forKey: .contextWindow)).flatMap(Self.validPositiveMeasurement)
        handoffTargetTokens = (try? container.decode(Int.self, forKey: .handoffTargetTokens)).flatMap(Self.validPositiveMeasurement)
        observedAt = try? container.decodeIfPresent(String.self, forKey: .observedAt)
    }

    private static func validNonnegativeMeasurement(_ value: Int) -> Int? {
        (0...maximumJSONSafeInteger).contains(value) ? value : nil
    }

    private static func validPositiveMeasurement(_ value: Int) -> Int? {
        (1...maximumJSONSafeInteger).contains(value) ? value : nil
    }

    var measuredFraction: Double? {
        guard status == .measured, let tokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, max(0, Double(tokens) / Double(contextWindow)))
    }

    enum ManagedHandoffPressure: Equatable, Sendable {
        case unknown
        case belowTarget
        case approaching
        case thresholdReached
    }

    var managedHandoffPressure: ManagedHandoffPressure {
        guard status == .measured, let tokens, let handoffTargetTokens else { return .unknown }
        if tokens >= handoffTargetTokens { return .thresholdReached }
        let warningThreshold = Int((Double(handoffTargetTokens) * 0.9).rounded(.up))
        return tokens >= warningThreshold ? .approaching : .belowTarget
    }

    var isNearManagedHandoff: Bool {
        managedHandoffPressure == .approaching || managedHandoffPressure == .thresholdReached
    }
}
