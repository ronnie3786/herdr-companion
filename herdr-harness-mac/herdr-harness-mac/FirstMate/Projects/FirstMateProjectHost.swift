import Foundation

struct FirstMateProjectHost: Identifiable, Equatable, Sendable {
    let machineID: String
    var machineName: String
    var serverID: String?
    var projects: [FirstMateProject] = []
    var supportsProjects = false
    var supportsDirectoryBrowser = false
    var isLoading = false
    var hasLoaded = false
    var isReachable = false
    var error: String?
    var lastUpdated: Date?

    var id: String { machineID }
    var canManageProjects: Bool { isReachable && supportsProjects && error == nil }
    var availabilityLabel: String {
        if isLoading && !hasLoaded { return "Connecting…" }
        if !isReachable { return "Unavailable" }
        if !supportsProjects { return "Companion update needed" }
        if error != nil { return "Projects unavailable" }
        return "Connected"
    }
}
