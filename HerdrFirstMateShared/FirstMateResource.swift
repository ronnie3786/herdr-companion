import Foundation

enum FirstMateResource: Identifiable {
    case document(FirstMateDocument)
    case session(FirstMateAssignment)
    case history(FirstMateSession)
    var id: String {
        switch self {
        case .document(let document): "document-\(document.id)"
        case .session(let agent): "session-\(agent.nativeSessionID ?? agent.id)-\(agent.generation)"
        case .history(let session): "session-\(session.nativeSessionID)-\(session.generation)"
        }
    }
    var title: String {
        switch self {
        case .document(let document): document.title
        case .session(let agent): agent.title
        case .history(let session): session.title
        }
    }
    var nativeSessionID: String? {
        switch self {
        case .document: nil
        case .session(let assignment): assignment.nativeSessionID
        case .history(let session): session.nativeSessionID
        }
    }
    var assignmentID: String? {
        switch self {
        case .document(let document): document.assignmentID
        case .session(let assignment): assignment.id
        case .history(let session): session.assignmentID
        }
    }
}
