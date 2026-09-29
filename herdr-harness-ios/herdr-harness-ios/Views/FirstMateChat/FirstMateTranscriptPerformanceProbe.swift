#if DEBUG
import Foundation

/// Opt-in synthetic-only counters. No observation invalidations while scrolling.
@MainActor
enum FirstMateTranscriptPerformanceProbe {
    nonisolated static let enabled = ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateTranscriptPerformance")
    private static var bodies: Set<String> = []
    private static var visible: Set<String> = []
    private static var seen: Set<String> = []
    private static var peak = 0
    static func evaluated(_ id: String) { if enabled { bodies.insert(id) } }
    static func appeared(_ id: String) {
        guard enabled else { return }
        visible.insert(id); seen.insert(id); peak = max(peak, visible.count)
    }
    static func disappeared(_ id: String) { if enabled { visible.remove(id) } }
    static var summary: String { "bodies=\(bodies.count); appeared=\(seen.count); visible=\(visible.count); peak=\(peak)" }
}
#endif
