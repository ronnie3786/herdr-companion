import Foundation

/// Stable, local artwork tokens shared by role settings and review runs.
enum AgentRoleAvatar: String, CaseIterable, Identifiable, Sendable {
    case review, code, architecture, quality, design, security, data, concurrency

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .review: "doc.text.magnifyingglass"
        case .code: "curlybraces"
        case .architecture: "square.stack.3d.up"
        case .quality: "checkmark.seal"
        case .design: "paintbrush.pointed"
        case .security: "lock.shield"
        case .data: "externaldrive"
        case .concurrency: "arrow.triangle.branch"
        }
    }
}
