import Foundation

/// Read freshness is retained by the store independently of published values.
/// A successful monitoring tick or an otherwise identical assessment does not
/// change the UI. Every verdict, evidence field and unhealthy heartbeat does.
enum FirstMatePollPresentation {
    static func sameFeature(_ lhs: FirstMateFeature, _ rhs: FirstMateFeature) -> Bool {
        var normalized = lhs
        normalized.verification?.computedAt = rhs.verification?.computedAt
        return normalized == rhs
    }

    static func sameFeatures(_ lhs: [FirstMateFeature], _ rhs: [FirstMateFeature]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameFeature)
    }

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
        normalized.feature.verification?.computedAt = rhs.feature.verification?.computedAt
        return normalized == rhs
    }
}
