import Foundation

struct FirstMateProjectChoice: Identifiable, Equatable, Sendable {
    let host: FirstMateProjectHost
    let project: FirstMateProject

    var id: FirstMateProjectSelection {
        .init(machineID: host.machineID, projectID: project.id)
    }
}
