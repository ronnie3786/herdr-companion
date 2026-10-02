import Foundation

struct FirstMateProjectSelection: Hashable, Identifiable, Sendable {
    let machineID: String
    let projectID: String

    var id: Self { self }
}
