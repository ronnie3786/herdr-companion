import Foundation

/// Separators follow visible chat adjacency, not model group membership. Call
/// separately for each section that has a heading, and for each expanded tab.
enum SidebarChatPresentation {
    static func dividerFlags(groupSizes: [Int]) -> [Bool] {
        let count = groupSizes.reduce(0, +)
        return (0..<count).map { $0 > 0 }
    }
}
