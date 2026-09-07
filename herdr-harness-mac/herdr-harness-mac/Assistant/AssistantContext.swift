import Foundation

struct AssistantContext: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var feature: String
        var instanceId: String
    }
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var kind: String
        var label: String
        var text: String
    }
    var version = 1
    var snapshotId = UUID().uuidString
    var capturedAt = Date.now.ISO8601Format()
    var source: Source
    var items: [Item]
}
