import Foundation

/// Presentation choices only. This never contains server configuration or transcript text.
struct HomeLocalPreferences: Codable {
    var version = 1
    var snoozes: [String: HomeEvidenceChoice] = [:]
    var dismissals: [String: HomeEvidenceChoice] = [:]
    var lastSeen: [String: Date] = [:]
    var lastVisit: Date?
    var recapExpanded = false

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        snoozes = snoozes.filter { id, choice in
            (choice.expiresAt ?? .distantPast) > now && (lastSeen[id] ?? .distantPast) >= cutoff
        }
        dismissals = dismissals.filter { id, _ in (lastSeen[id] ?? .distantPast) >= cutoff }
        lastSeen = lastSeen.filter { $0.value >= cutoff }
    }
}

struct HomeEvidenceChoice: Codable, Equatable {
    var fingerprint: String
    var expiresAt: Date?
}
