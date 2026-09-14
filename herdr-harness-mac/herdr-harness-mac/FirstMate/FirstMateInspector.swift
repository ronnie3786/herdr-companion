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
