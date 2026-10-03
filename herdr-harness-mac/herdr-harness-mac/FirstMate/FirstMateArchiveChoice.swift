import Foundation

struct FirstMateArchiveChoice: Identifiable {
    let resource: FirstMateArchiveResource
    var delete: Bool
    var id: String { resource.id }
}
