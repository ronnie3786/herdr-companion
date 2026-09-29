#if DEBUG
import Foundation

/// Synthetic UI-test instrumentation only. It does not observe or invalidate
/// the list on every row event, and never records feature content.
@MainActor
enum FirstMateListPerformanceProbe {
    nonisolated static let enabled = ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateListPerformance")
    private static var visible: Set<FirstMateFleetFeatureID> = []
    private static var appearedIDs: Set<FirstMateFleetFeatureID> = []
    private static var peak = 0
    private static var bodyIDs: Set<FirstMateFleetFeatureID> = []
    static func bodyEvaluated(_ id: FirstMateFleetFeatureID) {
        guard enabled else { return }
        bodyIDs.insert(id)
    }
    static func appeared(_ id: FirstMateFleetFeatureID) {
        guard enabled else { return }
        visible.insert(id); appearedIDs.insert(id); peak = max(peak, visible.count)
    }
    static func disappeared(_ id: FirstMateFleetFeatureID) {
        guard enabled else { return }
        visible.remove(id)
    }
    static var summary: String { "bodies=\(bodyIDs.count); appeared=\(appearedIDs.count); visible=\(visible.count); peak=\(peak)" }
}
#endif
