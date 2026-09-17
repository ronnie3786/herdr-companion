import Foundation

struct PiAssistantBlock: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case streaming
        case complete
        case failed(String?)
    }

    let id: String
    var text: String
    var status: Status
    var timestamp: Date? = nil
    /// Terminal reason reported for the containing assistant message. Older
    /// snapshots omit it, so nil remains an accepted compatibility value.
    var stopReason: String? = nil
}
