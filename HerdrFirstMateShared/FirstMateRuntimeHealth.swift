import Foundation

/// Optional additive contract: older companions do not report engine liveness.
struct FirstMateRuntimeHealth: Codable, Equatable, Sendable {
    var status: String
    var schedulerAlive: Bool
    var lastSuccessAt: String?
    var errorKind: String?
    var consecutiveFailures: Int
    var guardianAlive: Bool? = nil
    var automaticRecovery: Bool? = nil
    var sweepIntervalSeconds: Int? = nil
    var lastSweepAt: String? = nil
    var nextSweepAt: String? = nil
    var schedulerRestarts: Int? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case schedulerAlive = "scheduler_alive"
        case lastSuccessAt = "last_success_at"
        case errorKind = "error_kind"
        case consecutiveFailures = "consecutive_failures"
        case guardianAlive = "guardian_alive", automaticRecovery = "automatic_recovery"
        case sweepIntervalSeconds = "sweep_interval_seconds", lastSweepAt = "last_sweep_at"
        case nextSweepAt = "next_sweep_at", schedulerRestarts = "scheduler_restarts"
    }

    var warning: String? {
        switch status {
        case "healthy": nil
        case "starting": "First Mate is starting. Execution has not yet been verified."
        case "degraded" where errorKind == "storage_low":
            "First Mate is holding new launches to preserve its free-space reserve. It will retry automatically when space is available; existing work is retained."
        case "degraded" where errorKind == "storage_full":
            "First Mate cannot save progress because storage is full. Monitoring will retry automatically after space is available. Worker progress is unverified."
        case "degraded" where errorKind == "storage_unwritable":
            "First Mate cannot write its state. Check storage permissions. Monitoring will retry automatically; worker progress is unverified."
        case "degraded": "First Mate monitoring encountered an error and is retrying. Worker progress is unverified."
        case "stalled": "First Mate monitoring has stopped responding. The saved workflow status may be stale. Check the companion server."
        case "stopped": "First Mate monitoring is not running. The saved workflow status may be stale. Check the companion server."
        default: "First Mate execution health is unknown. Check the companion server."
        }
    }
}
