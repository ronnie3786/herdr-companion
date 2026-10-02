import Foundation

enum FirstMateStartMode: String, CaseIterable, Identifiable {
    case project = "Use a project"
    case manual = "Manual setup"
    var id: Self { self }
}
