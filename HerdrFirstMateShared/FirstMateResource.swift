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
    func usage(in snapshot: FirstMateSnapshot?) -> FirstMateUsage? {
        switch self {
        case .document:
            return nil
        case .session(let assignment):
            guard let nativeSessionID = assignment.nativeSessionID else { return nil }
            return snapshot?.sessions.first {
                $0.featureID == assignment.featureID && $0.nativeSessionID == nativeSessionID
            }?.usage
        case .history(let session):
            return session.usage
        }
    }

    func modelSelection(in snapshot: FirstMateSnapshot?) -> FirstMateModelSelection? {
        switch self {
        case .document:
            return nil
        case .session(let assignment):
            return assignment.modelSelection
        case .history(let session):
            return session.modelSelection
        }
    }
}
