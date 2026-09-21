import Foundation

struct AssistantContext: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var feature: String
        var instanceId: String
    }
    struct Item: Codable, Equatable, Identifiable, Sendable {
        struct Span: Codable, Equatable, Sendable {
            var side: String
            var startLine: Int
            var endLine: Int
        }

        struct Locator: Codable, Equatable, Sendable {
            var path: String? = nil
            var oldPath: String? = nil
            var section: String? = nil
            var revision: String? = nil
            var spans: [Span]? = nil
        }

        var id: String
        var kind: String
        var label: String
        var text: String
        var priority: String? = nil
        var locator: Locator? = nil
    }
    var version = 1
    var snapshotId = UUID().uuidString
    var capturedAt = Date.now.ISO8601Format()
    var source: Source
    var items: [Item]
}
