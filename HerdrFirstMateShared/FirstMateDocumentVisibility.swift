import Foundation

/// Presentation policy for the human-facing First Mate document collections.
///
/// Session handoff checkpoints remain in the snapshot for context, recovery,
/// and direct document lookup. They are omitted only from document-list
/// presentation, using the handoff record's exact document ID rather than a
/// title or content heuristic.
enum FirstMateDocumentVisibility {
    static func presentedDocuments(
        _ documents: [FirstMateDocument],
        handoffs: [FirstMateHandoff]
    ) -> [FirstMateDocument] {
        let handoffDocumentIDs = Set(handoffs.map(\.documentID))
        guard !handoffDocumentIDs.isEmpty else { return documents }
        return documents.filter { !handoffDocumentIDs.contains($0.id) }
    }
}
