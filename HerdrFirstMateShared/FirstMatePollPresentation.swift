import Foundation

/// Read freshness is retained by the store independently of published values.
/// A successful monitoring tick does not change the UI. Every other field and
/// an unhealthy heartbeat does.
enum FirstMatePollPresentation {
    static func sameHealth(_ lhs: FirstMateRuntimeHealth?, _ rhs: FirstMateRuntimeHealth?) -> Bool {
        var normalized = lhs
        // The warning displays lastSuccessAt when monitoring is unhealthy.
        if lhs?.status == "healthy", rhs?.status == "healthy" {
            normalized?.lastSuccessAt = rhs?.lastSuccessAt
        }
        return normalized == rhs
    }

    static func sameSnapshot(_ lhs: FirstMateSnapshot, _ rhs: FirstMateSnapshot) -> Bool {
        guard sameHealth(lhs.runtimeHealth, rhs.runtimeHealth) else { return false }
        var normalized = lhs
        normalized.runtimeHealth = rhs.runtimeHealth
        return normalized == rhs
    }
}
