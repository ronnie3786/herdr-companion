import Foundation

/// Counted nouns for First Mate's labels: "1 agent", "2 agents".
enum FirstMateCountText {
    static func phrase(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
