import Foundation

enum FirstMateInspector: String, CaseIterable, Identifiable {
    case overview = "Overview", agents = "Agents", documents = "Documents", workflow = "Workflow"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "person.2"
        case .documents: "doc.text"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// The Documents inspector's Documents/Links sub-tabs. Shared so Overview's
/// link management can navigate directly to the Links collection.
enum FirstMateDocumentsMode: String, CaseIterable, Identifiable {
    case documents = "Documents"
    case links = "Links"

    var id: Self { self }
    var title: String { rawValue }
}
