import Foundation

struct PaneLifecycleCapabilities: Decodable, Sendable {
    let capabilities: [String]?

    var supportsRetirement: Bool {
        capabilities?.contains("pane-retirement-v1") == true
    }
}
