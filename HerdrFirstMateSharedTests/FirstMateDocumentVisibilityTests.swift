import Foundation
import Testing
#if os(macOS)
@testable import herdr_harness_mac
#else
@testable import herdr_harness_ios
#endif

@Suite("First Mate document visibility")
struct FirstMateDocumentVisibilityTests {
    @Test("Handoff provenance hides only its exact retained document")
    func semanticHandoffVisibility() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        let visitID = try #require(snapshot.visits.first?.id)
        let assignmentID = try #require(snapshot.assignments.first?.id)
        let sessionID = try #require(snapshot.assignments.first?.nativeSessionID)
        let ordinaryNamedHandoff = document(
            id: "document-user-handoff-title",
            featureID: snapshot.feature.id,
            visitID: visitID,
            assignmentID: assignmentID,
            sessionID: sessionID,
            title: "Session handoff"
        )
        let trackedHandoff = document(
            id: "document-functional-checkpoint",
            featureID: snapshot.feature.id,
            visitID: visitID,
            assignmentID: assignmentID,
            sessionID: sessionID,
            title: "Implementation checkpoint"
        )
        snapshot.documents = [ordinaryNamedHandoff, trackedHandoff]
        snapshot.handoffs = [handoff(
            documentID: trackedHandoff.id,
            featureID: snapshot.feature.id,
            assignmentID: assignmentID,
            sessionID: sessionID
        )]

        #expect(snapshot.presentedDocuments.map(\.id) == [ordinaryNamedHandoff.id])
        #expect(snapshot.presentedDocuments(for: visitID).map(\.id) == [ordinaryNamedHandoff.id])
        #expect(snapshot.documents(for: visitID).map(\.id) == [ordinaryNamedHandoff.id, trackedHandoff.id])
        #expect(snapshot.documents.map(\.id) == [ordinaryNamedHandoff.id, trackedHandoff.id])
    }

    @Test("Snapshot decoding retains handoff tracking and legacy snapshots show every document")
    func handoffDecodingAndLegacyFallback() throws {
        var snapshot = FirstMateDemo.features(step: 0)[0]
        let document = try #require(snapshot.documents.first)
        let assignmentID = try #require(document.assignmentID)
        let sessionID = try #require(document.nativeSessionID)
        snapshot.handoffs = [handoff(
            documentID: document.id,
            featureID: snapshot.feature.id,
            assignmentID: assignmentID,
            sessionID: sessionID
        )]

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FirstMateSnapshot.self, from: encoded)
        #expect(decoded.handoffs == snapshot.handoffs)
        #expect(decoded.documents == snapshot.documents)
        #expect(!decoded.presentedDocuments.contains { $0.id == document.id })

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "handoffs")
        let legacy = try JSONDecoder().decode(
            FirstMateSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.handoffs.isEmpty)
        #expect(legacy.presentedDocuments == legacy.documents)
    }

    private func document(
        id: String,
        featureID: String,
        visitID: String,
        assignmentID: String,
        sessionID: String,
        title: String
    ) -> FirstMateDocument {
        FirstMateDocument(
            id: id,
            featureID: featureID,
            visitID: visitID,
            assignmentID: assignmentID,
            nativeSessionID: sessionID,
            title: title,
            mediaType: "text/markdown",
            contentHash: "synthetic-hash-\(id)",
            createdAt: "2030-01-01T12:00:00Z",
            content: "Synthetic retained content",
            generation: 1,
            inputRevision: 1
        )
    }

    private func handoff(
        documentID: String,
        featureID: String,
        assignmentID: String,
        sessionID: String
    ) -> FirstMateHandoff {
        FirstMateHandoff(
            id: "handoff-synthetic",
            assignmentID: assignmentID,
            featureID: featureID,
            predecessorGeneration: 1,
            predecessorSessionID: sessionID,
            successorSessionID: "session-successor",
            successorSessionFile: nil,
            successorOwner: "synthetic-worker",
            summary: "Synthetic checkpoint retained for continuation.",
            documentID: documentID,
            status: "completed",
            createdAt: "2030-01-01T12:00:00Z",
            updatedAt: "2030-01-01T12:01:00Z"
        )
    }
}
