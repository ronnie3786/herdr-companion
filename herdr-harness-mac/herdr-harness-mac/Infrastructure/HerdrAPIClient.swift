import Foundation
import os

private let piStreamLog = OSLog(subsystem: HerdrAppIdentity.bundleIdentifier, category: "pi-stream")

private struct PRReviewRequestID: Codable, Sendable {
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
    }
}

private struct FirstMateLinkVisibilityBody: Codable, Sendable {
    let hidden: Bool
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case hidden
        case requestID = "request_id"
    }
}

private struct PRReviewCreateBody: Codable, Sendable {
    let url: String
    let skillIDs: [String]
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case url
        case skillIDs = "skill_ids"
        case requestID = "request_id"
    }
}

private struct PRReviewRunBody: Codable, Sendable {
    let skillID: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case requestID = "request_id"
    }
}

private struct PRReviewFinishBody: Codable, Sendable {
    let state: String
    let note: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case state
        case note
        case requestID = "request_id"
    }
}

private struct PRReviewMarkBody: Codable, Sendable {
    let state: String
    let note: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case state
        case note
        case requestID = "request_id"
    }
}

private struct PRReviewRankingsBody: Codable, Sendable {
    let files: [[String: String]]
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case files
        case requestID = "request_id"
    }
}

private struct PRReviewViewedBody: Codable, Sendable {
    let paths: [String]
    let viewed: Bool
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case paths
        case viewed
        case requestID = "request_id"
    }
}

private struct PRReviewUploadDocumentBody: Codable, Sendable {
    let filename: String
    let contentType: String
    let dataBase64: String
    let title: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case dataBase64 = "data_base64"
        case title
        case requestID = "request_id"
    }
}

private struct PRReviewLinkDocumentBody: Codable, Sendable {
    let url: String
    let title: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case requestID = "request_id"
    }
}

private struct PRReviewPathDocumentBody: Codable, Sendable {
    let path: String
    let title: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case path
        case title
        case requestID = "request_id"
    }
}

private struct PRReviewSkillsResponse: Decodable, Sendable {
    let skills: [PRReviewSkill]
}

private struct PRReviewSkillResponse: Decodable, Sendable {
    let skill: PRReviewSkill
}

private struct PRReviewSkillStateResponse: Decodable, Sendable {
    let skill: PRReviewSkillState
}

private struct PRReviewRunResponse: Decodable, Sendable {
    let run: PRReviewRun
}

private struct PRReviewOutputResponse: Decodable, Sendable {
    let runID: String
    let lines: [String]
    let source: String

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case lines
        case source
    }
}

private struct PRReviewReviewResponse: Decodable, Sendable {
    let review: PRReviewSummary
}

private struct PRReviewFilesResponse: Decodable, Sendable {
    let files: [PRReviewFile]
}

private struct PRReviewDocumentsResponse: Decodable, Sendable {
    let documents: [PRReviewDocument]
}

private struct PRReviewDocumentResponse: Decodable, Sendable {
    let document: PRReviewDocument
}

private struct PRReviewEventsResponse: Decodable, Sendable {
    let events: [PRReviewEvent]
}

actor HerdrAPIClient: HerdrNotesClient, FirstMateClient, PRReviewClient, AgentProfilesClient {
    /// Nonisolated so the model can bind refreshed topology to the endpoint
    /// that produced it without another actor hop.
    nonisolated let configuration: ServerConfiguration
    private let session: URLSession
    private let cleanupApplyPollInterval: Duration
    private let cleanupApplyConsecutiveFailureLimit: Int
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        configuration: ServerConfiguration,
        session: URLSession = .shared,
        cleanupApplyPollInterval: Duration = .seconds(1),
        cleanupApplyConsecutiveFailureLimit: Int = 8
    ) {
        self.configuration = configuration
        self.session = session
        self.cleanupApplyPollInterval = cleanupApplyPollInterval
        self.cleanupApplyConsecutiveFailureLimit = max(1, cleanupApplyConsecutiveFailureLimit)
    }

    func fetchWorkspaces() async throws -> WorkspacesResponse {
        try await request(path: "/api/v1/workspaces")
    }

    func fetchFirstMateModels() async throws -> FirstMateModelCatalog {
        try await request(path: "/api/v1/first-mate/models")
    }

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        try await request(path: "/api/v1/first-mate/capabilities")
    }

    func setFirstMateModel(featureID: String, settings: FirstMateModelSettings) async throws -> FirstMateSnapshot {
        try await request(path: firstMatePath("features", id: featureID) + "/model-settings", method: "POST", body: settings)
    }

    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList {
        try await request(path: "/api/v1/first-mate/features")
    }

    func fetchFirstMateFeatures(scope: FirstMateFeatureScope) async throws -> FirstMateFeatureList {
        try await request(path: "/api/v1/first-mate/features", query: [URLQueryItem(name: "view", value: scope.rawValue)])
    }

    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        try await request(path: firstMatePath("features", id: id))
    }

    func fetchFirstMateGitWorkspaces(featureID: String) async throws -> FirstMateGitWorkspaceResponse {
        try await request(path: firstMatePath("features", id: featureID) + "/git/workspaces")
    }

    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        try await request(path: "/api/v1/first-mate/features", method: "POST", body: [
            "title": title, "goal": goal, "cwd": cwd, "request_id": requestID,
        ])
    }

    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot {
        try await request(path: firstMatePath("features", id: featureID) + "/messages", method: "POST", body: [
            "text": text, "request_id": requestID,
        ])
    }

    func uploadFirstMateAttachment(
        featureID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        let candidate = try AttachmentPolicy.candidate(for: fileURL, ownership: .userSelected)
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try AttachmentPolicy.validateFile(named: candidate.filename, byteCount: Int64(data.count))
        return try await request(
            path: firstMatePath("features", id: featureID) + "/attachments",
            method: "POST",
            body: WorkspaceAttachmentBody(
                filename: candidate.filename,
                contentType: contentType,
                dataBase64: data.base64EncodedString()
            )
        )
    }

    func transcribeFirstMateVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        try await transcribeVoice(fileURL: fileURL)
    }

    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot {
        try await request(path: firstMatePath("features", id: featureID) + "/actions", method: "POST", body: [
            "action": action, "request_id": requestID,
        ])
    }

    func setFirstMateArchived(featureID: String, archived: Bool, reason: FirstMateArchiveReason?, requestID: String) async throws -> FirstMateSnapshot {
        var body = ["request_id": requestID]
        if archived, let reason { body["reason"] = reason.rawValue }
        body["action"] = archived ? "archive" : "unarchive"
        return try await request(path: firstMatePath("features", id: featureID) + "/actions", method: "POST", body: body)
    }

    func saveFirstMateLink(featureID: String, url: String, title: String?, kind: String?, requestID: String) async throws -> FirstMateLinkMutationResponse {
        var body = ["url": url, "request_id": requestID]
        if let title, !title.isEmpty { body["title"] = title }
        if let kind, !kind.isEmpty { body["kind"] = kind }
        return try await request(path: firstMatePath("features", id: featureID) + "/links", method: "POST", body: body)
    }

    func setFirstMateLinkVisibility(featureID: String, linkID: String, hidden: Bool, requestID: String) async throws -> FirstMateLinkMutationResponse {
        let safeLinkID = try validatedFirstMateID(linkID)
        return try await request(
            path: firstMatePath("features", id: featureID) + "/links/\(safeLinkID)/visibility",
            method: "POST",
            body: FirstMateLinkVisibilityBody(hidden: hidden, requestID: requestID)
        )
    }

    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse {
        try await request(path: firstMatePath("documents", id: id))
    }

    func fetchFirstMateSession(_ id: String, before: Int? = nil) async throws -> FirstMateSessionResponse {
        var query = [URLQueryItem(name: "limit", value: "100")]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await request(path: firstMatePath("sessions", id: id), query: query)
    }

    private func firstMatePath(_ collection: String, id: String) throws -> String {
        "/api/v1/first-mate/\(collection)/\(try validatedFirstMateID(id))"
    }

    private func validatedFirstMateID(_ id: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard !id.isEmpty, id != ".", id != "..", id.count <= 256,
              id.unicodeScalars.allSatisfy(allowed.contains) else { throw APIError.invalidResponse }
        return id
    }

    // PR Review ids are server-issued opaque tokens. Validate them before they
    // become URL path components, just as First Mate ids are validated above.
    private func prReviewPath(_ collection: String = "", id: String? = nil) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ .").subtracting(CharacterSet(charactersIn: " ")))
        if let id {
            guard !id.isEmpty, id != ".", id != "..", id.count <= 256,
                  id.unicodeScalars.allSatisfy(allowed.contains) else { throw APIError.invalidResponse }
        }
        let suffix = [collection, id].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        return "/api/v1/pr-reviews" + (suffix.isEmpty ? "" : "/" + suffix)
    }

    func prReviewCapabilities() async throws -> PRReviewCapabilities { try await request(path: try prReviewPath("capabilities")) }
    func prReviewSkills() async throws -> [PRReviewSkill] { let r: PRReviewSkillsResponse = try await request(path: try prReviewPath("skills")); return r.skills }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { let r: PRReviewSkillResponse = try await request(path: try prReviewPath("skills"), method: "POST", body: body); return r.skill }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { let r: PRReviewSkillsResponse = try await request(path: try prReviewPath("skills", id: id), method: "DELETE", body: PRReviewRequestID(requestID: requestID)); return r.skills }
    func prReviews(scope: String = "active") async throws -> [PRReviewSummary] { let r: PRReviewListResponse = try await request(path: try prReviewPath(), query: [.init(name: "scope", value: scope)]); return r.reviews }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot { try await request(path: try prReviewPath(), method: "POST", body: PRReviewCreateBody(url: url, skillIDs: skillIDs, requestID: requestID)) }
    func prReview(id: String) async throws -> PRReviewSnapshot { try await request(path: try prReviewPath(id: id)) }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot { try await request(path: try prReviewPath(id: id) + "/refresh", method: "POST", body: PRReviewRequestID(requestID: requestID)) }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot { try await request(path: try prReviewPath(id: id) + (archived ? "/archive" : "/unarchive"), method: "POST", body: PRReviewRequestID(requestID: requestID)) }
    func prReviewDiff(id: String, path: String? = nil) async throws -> PRReviewDiff { try await request(path: try prReviewPath(id: id) + "/diff", query: path.map { [.init(name: "path", value: $0)] } ?? []) }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText { var q=[URLQueryItem(name:"path",value:path),.init(name:"side",value:side.rawValue)]; if let start { q.append(.init(name:"start",value:String(start))) }; if let end { q.append(.init(name:"end",value:String(end))) }; return try await request(path: try prReviewPath(id:id)+"/file",query:q) }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { try await request(path: try prReviewPath(id:id)+"/findings",query:[.init(name:"path",value:path)]) }
    func createPRReviewRun(id:String,skillID:String,requestID:String) async throws -> PRReviewRun { let r:PRReviewRunResponse=try await request(path:try prReviewPath(id:id)+"/runs",method:"POST",body:PRReviewRunBody(skillID:skillID,requestID:requestID));return r.run }
    func prReviewRun(reviewID:String,runID:String) async throws -> PRReviewRun { let r:PRReviewRunResponse=try await request(path:try prReviewPath(id:reviewID)+"/runs/"+validatedPRReviewID(runID));return r.run }
    func finishPRReviewRun(reviewID:String,runID:String,state:PRReviewRunState,note:String?,requestID:String) async throws -> PRReviewRun { let r:PRReviewRunResponse=try await request(path:try prReviewPath(id:reviewID)+"/runs/"+validatedPRReviewID(runID)+"/finish",method:"POST",body:PRReviewFinishBody(state:state.rawValue,note:note,requestID:requestID));return r.run }
    func prReviewRunOutput(reviewID:String,runID:String,lines:Int) async throws -> String { let r:PRReviewOutputResponse=try await request(path:try prReviewPath(id:reviewID)+"/runs/"+validatedPRReviewID(runID)+"/output",query:[.init(name:"lines",value:String(lines))]);return r.lines.joined(separator:"\n") }
    func markPRReviewSkill(reviewID:String,skillID:String,state:String,note:String?,requestID:String) async throws -> PRReviewSkillState { let r:PRReviewSkillStateResponse=try await request(path:try prReviewPath(id:reviewID)+"/skills/"+validatedPRReviewID(skillID)+"/mark",method:"POST",body:PRReviewMarkBody(state:state,note:note,requestID:requestID));return r.skill }
    func rankPRReview(id:String,requestID:String) async throws -> PRReviewSummary { let r:PRReviewReviewResponse=try await request(path:try prReviewPath(id:id)+"/rank",method:"POST",body:PRReviewRequestID(requestID:requestID));return r.review }
    func setPRReviewRankings(id:String,files:[[String:String]],requestID:String) async throws -> [PRReviewFile] { let r:PRReviewFilesResponse=try await request(path:try prReviewPath(id:id)+"/rankings",method:"PUT",body:PRReviewRankingsBody(files:files,requestID:requestID));return r.files }
    func setPRReviewViewed(id:String,paths:[String],viewed:Bool,requestID:String) async throws -> [PRReviewFile] { let r:PRReviewFilesResponse=try await request(path:try prReviewPath(id:id)+"/viewed",method:"POST",body:PRReviewViewedBody(paths:paths,viewed:viewed,requestID:requestID));return r.files }
    func syncPRReviewViewed(id:String,requestID:String) async throws -> [PRReviewFile] { let r:PRReviewFilesResponse=try await request(path:try prReviewPath(id:id)+"/viewed/sync",method:"POST",body:PRReviewRequestID(requestID:requestID));return r.files }
    func prReviewDocuments(id:String) async throws -> [PRReviewDocument] { let r:PRReviewDocumentsResponse=try await request(path:try prReviewPath(id:id)+"/documents");return r.documents }
    func addPRReviewDocument(
        id: String,
        payload: PRReviewDocumentPayload,
        requestID: String
    ) async throws -> PRReviewDocument {
        let path = try prReviewPath(id: id) + "/documents"
        let response: PRReviewDocumentResponse

        switch payload {
        case let .upload(filename, contentType, dataBase64, title):
            let body = PRReviewUploadDocumentBody(
                filename: filename,
                contentType: contentType,
                dataBase64: dataBase64,
                title: title,
                requestID: requestID
            )
            response = try await request(path: path, method: "POST", body: body)
        case let .link(url, title):
            let body = PRReviewLinkDocumentBody(
                url: url,
                title: title,
                requestID: requestID
            )
            response = try await request(path: path, method: "POST", body: body)
        case let .path(filePath, title):
            let body = PRReviewPathDocumentBody(
                path: filePath,
                title: title,
                requestID: requestID
            )
            response = try await request(path: path, method: "POST", body: body)
        }

        return response.document
    }
    func prReviewDocument(reviewID:String,documentID:String) async throws -> PRReviewDocument { let r:PRReviewDocumentResponse=try await request(path:try prReviewPath(id:reviewID)+"/documents/"+validatedPRReviewID(documentID));return r.document }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws {
        guard destinationURL.isFileURL, (0...2 * 1024 * 1024 * 1024).contains(expectedByteSize) else { throw APIError.invalidResponse }
        let request = makeRequest(path: try prReviewPath(id: reviewID) + "/documents/" + validatedPRReviewID(documentID) + "/content", method: "GET")
        let limiter = ResultArtifactDownloadLimiter(maximumByteCount: expectedByteSize)
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request, delegate: limiter)
        } catch {
            if limiter.exceededLimit { throw APIError.invalidResponse }
            throw error
        }
        try Self.validate(response: response)
        try Task.checkCancellation()
        guard response.expectedContentLength == expectedByteSize else { throw APIError.invalidResponse }
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == Int(expectedByteSize) else { throw APIError.invalidResponse }
        let fm = FileManager.default; try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destinationURL.deletingLastPathComponent().appending(path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: temporary, to: staging)
        if !fm.fileExists(atPath: destinationURL.path) { try fm.moveItem(at: staging, to: destinationURL) }
    }
    func prReviewEvents(id:String,after:Int?) async throws -> [PRReviewEvent] { let r:PRReviewEventsResponse=try await request(path:try prReviewPath(id:id)+"/events",query:after.map{[.init(name:"after",value:String($0))]} ?? []);return r.events }

    private func validatedPRReviewID(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id }

    func fetchNotes() async throws -> HerdrNotesCollection {
        try await request(path: "/api/v1/notes")
    }

    func importNotes(_ notes: [HerdrNote]) async throws -> HerdrNotesCollection {
        try await request(path: "/api/v1/notes/import", method: "POST", body: HerdrNotesImportRequest(notes: notes))
    }

    func createNote(_ note: HerdrNote) async throws -> HerdrSyncedNote {
        let response: HerdrNoteMutationResponse = try await notesMutation(
            path: "/api/v1/notes", method: "POST", body: HerdrNoteCreateRequest(note: note)
        )
        return response.note
    }

    func updateNote(_ note: HerdrNote, expectedRevision: Int) async throws -> HerdrSyncedNote {
        let response: HerdrNoteMutationResponse = try await notesMutation(
            path: "/api/v1/notes/\(note.id.uuidString)", method: "PATCH",
            body: HerdrNoteUpdateRequest(expectedRevision: expectedRevision, changes: .init(note: note))
        )
        return response.note
    }

    func deleteNote(id: UUID, expectedRevision: Int) async throws {
        let _: HerdrNoteDeleteResponse = try await notesMutation(
            path: "/api/v1/notes/\(id.uuidString)", method: "DELETE",
            body: HerdrNoteDeleteRequest(expectedRevision: expectedRevision)
        )
    }

    private func notesMutation<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String, method: String, body: Body
    ) async throws -> Response {
        var request = makeRequest(path: path, method: method)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            let conflict = try decoder.decode(HerdrNotesConflictResponse.self, from: data)
            if ["note_conflict", "note_deleted"].contains(conflict.error.code) {
                throw HerdrNotesConflictError(currentNote: conflict.currentNote)
            }
        }
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    func fetchHealthProbe() async throws -> HealthProbeResponse {
        try await request(path: "/api/v1/health")
    }

    func fetchAgentProfiles() async throws -> AgentProfilesOverview {
        try await request(path: "/api/v1/agent-profiles")
    }

    func fetchAgentProfile(id: String) async throws -> AgentProfileHistoryResponse {
        guard UUID(uuidString: id) != nil else { throw APIError.invalidResponse }
        return try await request(path: "/api/v1/agent-profiles/profiles/\(id)")
    }

    func mutateAgentProfiles(_ mutation: AgentProfileMutation) async throws -> AgentProfileMutationResponse {
        try await request(path: "/api/v1/agent-profiles", method: "POST", body: mutation)
    }

    /// Reads the machine's inventory from the Fleet contract. Fleet is kept as
    /// a first-class client method so callers do not need to know request
    /// headers, authentication, or the endpoint's URL shape.
    func fetchFleet() async throws -> FleetResponse {
        try await request(path: "/api/v1/fleet")
    }

    /// Starts reconciliation for the requested machines. A nil list means the
    /// server's complete fleet, which is useful for the Sync All control.
    func syncFleet() async throws -> FleetSyncResponse {
        try await request(
            path: "/api/v1/fleet/sync",
            method: "POST",
            body: FleetSyncRequest()
        )
    }

    /// Performs one explicit inventory action. Removal is guarded in the
    /// SwiftUI layer for external items, while `force` remains available for
    /// a future server-side confirmation token.
    func performFleetAction(
        machineID: String,
        itemID: String,
        action: FleetAction,
        force: Bool = false
    ) async throws -> FleetActionResponse {
        // The server resolves the authenticated machine from the client
        // connection. Keep the machine id in the app-facing API for store
        // routing, but do not send it as an unrecognised backend field.
        _ = machineID
        _ = force
        let response: FleetActionResponse = try await request(
            path: "/api/v1/fleet/action",
            method: "POST",
            body: FleetActionRequest(
                itemID: itemID,
                action: action
            )
        )
        return response
    }

    func fetchNetworkInfo() async throws -> NetworkInfoResponse {
        try await request(path: "/api/v1/network")
    }

    func fetchMachineConfiguration() async throws -> HerdrMachineConfigurationResponse {
        try await request(path: "/api/v1/config/machines")
    }

    func fetchResponseAudioCapabilities() async throws -> ResponseAudioCapabilities {
        try await request(path: "/api/v1/response-audio/capabilities")
    }

    func submitQuickVoice(_ body: QuickVoiceRequest) async throws -> QuickVoiceEnvelope {
        try await request(path: "/api/v1/quick-voice", method: "POST", body: body)
    }

    func fetchQuickVoiceNotes() async throws -> QuickVoiceList {
        try await request(path: "/api/v1/quick-voice")
    }

    func fetchQuickVoiceAudio(jobID: String, messageID: String) async throws -> ResponseAudioSpeechResponse {
        try await request(path: "/api/v1/quick-voice/\(jobID)/audio/\(messageID)")
    }

    func prepareResponseAudio(
        action: ResponseAudioAction,
        text: String
    ) async throws -> ResponseAudioPrepareResponse {
        try await request(
            path: "/api/v1/response-audio/prepare",
            method: "POST",
            body: ResponseAudioPrepareBody(action: action, text: text)
        )
    }

    func synthesizeResponseAudio(text: String) async throws -> ResponseAudioSpeechResponse {
        try await request(
            path: "/api/v1/response-audio/speech",
            method: "POST",
            body: ResponseAudioSpeechBody(text: text)
        )
    }

    func fetchPaneOutput(paneID: String, lines: Int = 160) async throws -> PaneOutputResponse {
        try await request(
            path: "/api/v1/panes/\(paneID)/output",
            query: [
                URLQueryItem(name: "source", value: "recent_unwrapped"),
                URLQueryItem(name: "lines", value: String(lines)),
            ]
        )
    }

    func fetchGitStatus(workspaceID: String) async throws -> WorkspaceGitStatus {
        try await request(path: "/api/v1/workspaces/\(workspaceID)/git")
    }

    func fetchGitStatus(paneID: String) async throws -> WorkspaceGitStatus {
        try await request(path: "/api/v1/panes/\(paneID)/git")
    }

    func startCleanupRun(_ request: CleanupStartRunRequest) async throws -> CleanupStartRunResponse {
        try await self.request(path: "/api/v1/cleanup/runs", method: "POST", body: request)
    }

    func fetchCleanupRun(id: String) async throws -> CleanupRunEnvelope {
        try await request(path: "/api/v1/cleanup/runs/\(id)")
    }

    func fetchCleanupRuns(limit: Int = 10) async throws -> CleanupRunListResponse {
        try await request(
            path: "/api/v1/cleanup/runs",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func applyCleanupRun(
        id: String,
        paneIDs: [String],
        workspaceIDs: [String],
        onProgress: @Sendable (CleanupRunEnvelope) async -> Void = { _ in }
    ) async throws -> CleanupApplyResponse {
        if let completed = try await startCleanupApply(
            id: id,
            paneIDs: paneIDs,
            workspaceIDs: workspaceIDs,
            onProgress: onProgress
        ) {
            return completed
        }

        var consecutiveFailures = 0
        while true {
            try Task.checkCancellation()
            do {
                let envelope = try await fetchCleanupRun(id: id)
                await onProgress(envelope)
                if envelope.run.status == .applied || envelope.run.status == .failed,
                   let result = envelope.applyResult {
                    return result
                }
                if envelope.run.status == .applied || envelope.run.status == .failed {
                    consecutiveFailures += 1
                    guard consecutiveFailures < cleanupApplyConsecutiveFailureLimit else {
                        throw Self.cleanupApplyStatusUnknownError(
                            stage: "reading the final cleanup result",
                            lastError: APIError.invalidResponse
                        )
                    }
                } else {
                    consecutiveFailures = 0
                }
            } catch {
                if let apiError = error as? APIError,
                   case .cleanupApplyStatusUnknown = apiError {
                    throw apiError
                }
                try Self.rethrowIfCancelled(error)
                consecutiveFailures += 1
                guard consecutiveFailures < cleanupApplyConsecutiveFailureLimit else {
                    throw Self.cleanupApplyStatusUnknownError(
                        stage: "checking cleanup status",
                        lastError: error
                    )
                }
            }
            try await Task.sleep(for: cleanupApplyPollInterval)
        }
    }

    private func startCleanupApply(
        id: String,
        paneIDs: [String],
        workspaceIDs: [String],
        onProgress: @Sendable (CleanupRunEnvelope) async -> Void
    ) async throws -> CleanupApplyResponse? {
        var consecutivePostFailures = 0
        var consecutiveProbeFailures = 0
        while true {
            try Task.checkCancellation()

            let envelope: CleanupRunEnvelope
            do {
                envelope = try await fetchCleanupRun(id: id)
            } catch {
                try Self.rethrowIfCancelled(error)
                consecutiveProbeFailures += 1
                guard consecutiveProbeFailures < cleanupApplyConsecutiveFailureLimit else {
                    throw Self.cleanupApplyStatusUnknownError(
                        stage: "checking cleanup status before retrying",
                        lastError: error
                    )
                }
                try await Task.sleep(for: cleanupApplyPollInterval)
                continue
            }

            await onProgress(envelope)
            if envelope.run.status == .applied || envelope.run.status == .failed {
                if let result = envelope.applyResult { return result }
                consecutiveProbeFailures += 1
                guard consecutiveProbeFailures < cleanupApplyConsecutiveFailureLimit else {
                    throw Self.cleanupApplyStatusUnknownError(
                        stage: "reading the final cleanup result",
                        lastError: APIError.invalidResponse
                    )
                }
                try await Task.sleep(for: cleanupApplyPollInterval)
                continue
            }

            guard envelope.run.status == .done
                    || envelope.run.status == .partial
                    || envelope.run.status == .applying
            else {
                consecutiveProbeFailures += 1
                guard consecutiveProbeFailures < cleanupApplyConsecutiveFailureLimit else {
                    throw Self.cleanupApplyStatusUnknownError(
                        stage: "waiting for cleanup to become applicable",
                        lastError: APIError.invalidResponse
                    )
                }
                try await Task.sleep(for: cleanupApplyPollInterval)
                continue
            }
            consecutiveProbeFailures = 0

            do {
                let response: CleanupStartRunResponse = try await request(
                    path: "/api/v1/cleanup/runs/\(id)/apply",
                    method: "POST",
                    body: CleanupApplyRequest(paneIDs: paneIDs, workspaceIDs: workspaceIDs)
                )
                guard response.ok, response.runID == id else { throw APIError.invalidResponse }
                return nil
            } catch {
                try Self.rethrowIfCancelled(error)
                guard Self.isRetryableCleanupApplyStartError(error) else { throw error }
                consecutivePostFailures += 1
                guard consecutivePostFailures < cleanupApplyConsecutiveFailureLimit else {
                    throw Self.cleanupApplyStatusUnknownError(
                        stage: "starting cleanup",
                        lastError: error
                    )
                }
                try await Task.sleep(for: cleanupApplyPollInterval)
            }
        }
    }

    private static func isRetryableCleanupApplyStartError(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let error = error as? APIError {
            switch error {
            case .invalidResponse:
                return true
            case let .server(status, _):
                return status == 408 || status == 409 || status == 429 || (500...599).contains(status)
            case .noActiveConnection, .cleanupApplyStatusUnknown, .streamEnded, .streamBacklogOverflow:
                return false
            }
        }
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .badServerResponse:
            return true
        default:
            return false
        }
    }

    private static func rethrowIfCancelled(_ error: Error) throws {
        if HerdrCancellation.isCancellation(error) {
            throw CancellationError()
        }
    }

    private static func cleanupApplyStatusUnknownError(stage: String, lastError: Error) -> APIError {
        APIError.cleanupApplyStatusUnknown(
            message: "Herdr could not confirm cleanup while \(stage) after repeated attempts. "
                + "The server may still be ending sessions or closing panes. Last error: \(lastError.localizedDescription)"
        )
    }

    func cancelCleanupRun(id: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/cleanup/runs/\(id)/cancel",
            method: "POST",
            body: APIActionBody()
        )
    }

    func fetchCleanupModels() async throws -> CleanupModelCatalog {
        try await request(path: "/api/v1/cleanup/models")
    }

    func fetchGitDiff(
        workspaceID: String,
        file: String,
        section: GitFileSection
    ) async throws -> WorkspaceGitDiffResponse {
        try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/diff",
            query: [
                URLQueryItem(name: "file", value: file),
                URLQueryItem(name: "section", value: section.rawValue),
            ]
        )
    }

    func stageGitFile(workspaceID: String, file: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/stage",
            method: "POST",
            body: WorkspaceGitFileBody(file: file)
        )
    }

    func unstageGitFile(workspaceID: String, file: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/unstage",
            method: "POST",
            body: WorkspaceGitFileBody(file: file)
        )
    }

    func fetchSkills(workspaceID: String) async throws -> SkillsResponse {
        try await request(path: "/api/v1/workspaces/\(workspaceID)/skills")
    }

    func searchFiles(
        workspaceID: String,
        query: String,
        limit: Int = 80
    ) async throws -> FileSearchResponse {
        try await request(
            path: "/api/v1/workspaces/\(workspaceID)/files",
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func fetchAssignedJiraTickets(limit: Int = 50) async throws -> JiraTicketsResponse {
        try await request(
            path: "/api/v1/jira/assigned",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func fetchWorkInbox() async throws -> WorkInboxResponse {
        try await request(path: "/api/v1/work-inbox")
    }

    func fetchActiveWork() async throws -> ActiveWorkResponse {
        try await request(path: "/api/v1/active-work")
    }

    func setupActiveWorkJira(key: String) async throws -> ActiveWorkItemEnvelope {
        let safeKey = key.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? key
        return try await request(
            path: "/api/v1/active-work/jira/\(safeKey)/setup",
            method: "POST",
            body: APIActionBody()
        )
    }

    func createActiveWorkItem(
        _ requestBody: ActiveWorkCreateItemRequest
    ) async throws -> ActiveWorkItemEnvelope {
        try await request(
            path: "/api/v1/active-work/items",
            method: "POST",
            body: requestBody
        )
    }

    func transitionActiveWorkItem(
        id: String,
        requestBody: ActiveWorkTransitionRequest
    ) async throws -> ActiveWorkItemEnvelope {
        let safeID = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? id
        return try await request(
            path: "/api/v1/active-work/items/\(safeID)/transitions",
            method: "POST",
            body: requestBody
        )
    }

    func patchActiveWorkItem(
        id: String,
        requestBody: ActiveWorkPatchItemRequest
    ) async throws -> ActiveWorkItemEnvelope {
        let safeID = id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? id
        return try await request(
            path: "/api/v1/active-work/items/\(safeID)",
            method: "PATCH",
            body: requestBody
        )
    }

    func fetchJiraTicket(query: String) async throws -> JiraTicketResponse {
        try await request(
            path: "/api/v1/jira/issue",
            query: [URLQueryItem(name: "q", value: query)]
        )
    }

    func uploadAttachment(
        workspaceID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        let candidate = try AttachmentPolicy.candidate(
            for: fileURL,
            ownership: .userSelected
        )
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { fileURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try AttachmentPolicy.validateFile(
            named: candidate.filename,
            byteCount: Int64(data.count)
        )
        return try await request(
            path: "/api/v1/workspaces/\(workspaceID)/attachments",
            method: "POST",
            body: WorkspaceAttachmentBody(
                filename: fileURL.lastPathComponent,
                contentType: contentType,
                dataBase64: data.base64EncodedString()
            )
        )
    }

    func transcribeVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        let data = try VoiceRecordingPolicy.validatedData(at: fileURL)
        return try await request(
            path: "/api/v1/voice/transcriptions",
            method: "POST",
            body: VoiceTranscriptionRequest(
                filename: fileURL.lastPathComponent,
                mimeType: "audio/wav",
                dataBase64: data.base64EncodedString()
            )
        )
    }

    func createWorkspace(label: String, cwd: String) async throws {
        try await mutation(path: "/api/v1/workspaces", body: APIActionBody(label: label, cwd: cwd))
    }

    func renameWorkspace(id: String, label: String) async throws {
        try await mutation(
            path: "/api/v1/workspaces/\(id)",
            method: "PATCH",
            body: APIActionBody(label: label)
        )
    }

    func closeWorkspace(id: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(id)", method: "DELETE", body: APIActionBody())
    }

    func focusWorkspace(id: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(id)/focus", body: APIActionBody())
    }

    func createTab(workspaceID: String, label: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(workspaceID)/tabs", body: APIActionBody(label: label))
    }

    func renameTab(id: String, label: String) async throws {
        try await mutation(
            path: "/api/v1/tabs/\(id)",
            method: "PATCH",
            body: APIActionBody(label: label)
        )
    }

    func createQuickPiSession(
        label: String,
        requestID: String,
        workspaceID: String? = nil,
        tabID: String? = nil,
        cwd: String? = nil,
        sessionFile: String? = nil,
        sessionID: String? = nil,
        workspaceLabel: String? = nil,
        tabLabel: String? = nil,
        reuseNamedTab: Bool? = nil
    ) async throws -> QuickPiSessionResponse {
        let response: QuickPiSessionResponse = try await request(
            path: "/api/v1/quick-sessions/pi",
            method: "POST",
            body: QuickPiSessionRequest(
                label: label,
                requestID: requestID,
                workspaceID: workspaceID,
                tabID: tabID,
                cwd: cwd,
                sessionFile: sessionFile,
                sessionID: sessionID,
                workspaceLabel: workspaceLabel,
                tabLabel: tabLabel,
                reuseNamedTab: reuseNamedTab
            )
        )
        guard response.ok,
              !response.workspaceID.isEmpty,
              !response.tabID.isEmpty,
              !response.paneID.isEmpty,
              response.createdPane,
              response.requestID == requestID
        else { throw APIError.invalidResponse }
        return response
    }

    func fetchAlerts(limit: Int = 500) async throws -> AlertsResponse {
        try await request(
            path: "/api/v1/alerts",
            query: [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500)))]
        )
    }

    func fetchResultArtifacts() async throws -> ResultArtifactsResponse {
        try await request(path: "/api/v1/result-artifacts")
    }

    /// Streams an authenticated result payload to a temporary download and
    /// atomically installs it at the caller's cache destination. Result IDs are
    /// deliberately restricted to one URL path segment.
    func downloadResultArtifactContent(
        id: String,
        expectedByteSize: Int64,
        to destinationURL: URL
    ) async throws {
        guard Self.isValidResultArtifactID(id),
              destinationURL.isFileURL,
              (0...AgentResultArtifact.maximumDownloadByteSize).contains(expectedByteSize)
        else {
            throw APIError.invalidResponse
        }

        var request = makeRequest(
            path: "/api/v1/result-artifacts/\(id)/content",
            method: "GET"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let limiter = ResultArtifactDownloadLimiter(maximumByteCount: expectedByteSize)
        let downloadURL: URL
        let response: URLResponse
        do {
            (downloadURL, response) = try await session.download(for: request, delegate: limiter)
        } catch {
            if let status = limiter.failureStatus {
                if let mapped = AgentResultArtifactAvailabilityError.fromHTTPStatus(status) { throw mapped }
                throw APIError.server(status: status, message: "")
            }
            if limiter.exceededLimit { throw APIError.invalidResponse }
            throw AgentResultArtifactAvailabilityError.normalized(error)
        }
        do { try Self.validate(response: response) }
        catch { throw AgentResultArtifactAvailabilityError.normalized(error) }
        try Task.checkCancellation()

        guard response.expectedContentLength == expectedByteSize else {
            throw APIError.invalidResponse
        }
        let downloadedValues = try downloadURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard downloadedValues.isRegularFile == true,
              downloadedValues.isSymbolicLink != true,
              Int64(downloadedValues.fileSize ?? -1) == expectedByteSize
        else { throw APIError.invalidResponse }

        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw APIError.invalidResponse
        }
        let stagingURL = directory.appending(
            path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: downloadURL, to: stagingURL)
        try Task.checkCancellation()

        // Artifact content is immutable. Another task winning the same cache
        // install race is therefore equivalent to this download succeeding.
        if fileManager.fileExists(atPath: destinationURL.path) { return }
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }

    func assistantCapabilities() async throws -> AssistantCapabilities {
        try await request(path: "/api/v1/agent-runs/capabilities")
    }

    func serverCapabilities() async throws -> ServerCapabilities {
        try await request(path: "/api/v1")
    }

    func issueReportCapabilities() async throws -> IssueReportCapabilities {
        try await request(path: "/api/v1/issue-reports/capabilities")
    }

    /// Files a bug report or feature request as a public GitHub issue.
    ///
    /// Checks `issue-reports-v1` first so an older companion server produces a
    /// clear "update the server" error instead of a 404 after a 40 MB upload.
    func submitIssueReport(_ report: IssueReportRequest) async throws -> IssueReportRecord {
        try await requireIssueReports()
        let response: IssueReportResponse = try await request(
            path: "/api/v1/issue-reports", method: "POST", body: report
        )
        guard response.ok else { throw APIError.invalidResponse }
        return response.report
    }

    private func requireIssueReports() async throws {
        let response = try await serverCapabilities()
        guard response.supportsIssueReports else {
            throw APIError.server(status: 426, message: "Update the companion server to file bug reports and feature requests from the app.")
        }
    }

    func startAssistant(_ body: AssistantRequest) async throws -> HeadlessAgentRunEnvelope {
        try await request(path: "/api/v1/agent-runs", method: "POST", body: body)
    }

    func startHeadlessAgent(
        prompt: String,
        cwd: String? = nil,
        mode: HeadlessAgentRunMode = .ask,
        model: String? = nil,
        thinkingLevel: String? = nil,
        attachments: [HeadlessAgentAttachment]? = nil,
        continueFromRunId: String? = nil,
        systemPrompt: String? = nil,
        profile: String? = nil
    ) async throws -> HeadlessAgentRunEnvelope {
        try await request(
            path: "/api/v1/agent-runs",
            method: "POST",
            body: HeadlessAgentStartRequest(
                prompt: prompt,
                cwd: cwd,
                mode: mode,
                model: model,
                thinkingLevel: thinkingLevel,
                attachments: attachments,
                continueFromRunId: continueFromRunId,
                systemPrompt: systemPrompt,
                profile: profile
            )
        )
    }

    func hudChats(query: String, offset: Int = 0) async throws -> HudChatCatalog {
        try await request(path: "/api/v1/hud-chats", query: [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "offset", value: String(offset))
        ])
    }

    func hudChat(id: String, offset: Int = 0) async throws -> HudChatHistory {
        try await request(path: "/api/v1/hud-chats/\(id)", query: [URLQueryItem(name: "offset", value: String(offset))])
    }

    func saveHudChat(id: String) async throws {
        let _: MutationResponse = try await request(path: "/api/v1/hud-chats/\(id)", method: "POST", body: APIActionBody())
    }

    func fetchHeadlessAgent(id: String) async throws -> HeadlessAgentRunEnvelope {
        try await request(path: "/api/v1/agent-runs/\(id)")
    }

    func fetchAgentModels() async throws -> AgentModelCatalogResponse {
        try await request(path: "/api/v1/agent-runs/models")
    }

    func fetchAgentPromptDefaults() async throws -> AgentPromptDefaultsResponse {
        try await request(path: "/api/v1/agent-runs/prompts")
    }

    func cancelHeadlessAgent(id: String) async throws -> HeadlessAgentRunEnvelope {
        try await request(
            path: "/api/v1/agent-runs/\(id)/cancel",
            method: "POST",
            body: APIActionBody()
        )
    }

    func deleteHeadlessAgent(id: String) async throws -> HeadlessAgentRunEnvelope {
        try await request(
            path: "/api/v1/agent-runs/\(id)",
            method: "DELETE",
            body: APIActionBody()
        )
    }

    func promoteHeadlessAgent(
        id: String,
        workspaceID: String?,
        cwd: String? = nil,
        workspaceLabel: String? = nil
    ) async throws -> HeadlessAgentRunEnvelope {
        try await request(
            path: "/api/v1/agent-runs/\(id)/promote",
            method: "POST",
            body: HeadlessAgentPromotionRequest(
                workspaceID: workspaceID,
                cwd: cwd,
                workspaceLabel: workspaceLabel
            )
        )
    }

    func splitPane(id: String, direction: String) async throws -> String? {
        let response: SplitPaneResponse = try await request(
            path: "/api/v1/panes/\(id)/split",
            method: "POST",
            body: APIActionBody(direction: direction, ratio: 0.5)
        )
        return response.paneID
    }

    func renamePane(id: String, label: String) async throws {
        try await mutation(
            path: "/api/v1/panes/\(id)",
            method: "PATCH",
            body: APIActionBody(label: label)
        )
    }

    func focusPane(id: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/focus", body: APIActionBody())
    }

    func zoomPane(id: String, mode: String = "on") async throws {
        try await mutation(path: "/api/v1/panes/\(id)/zoom", body: APIActionBody(mode: mode))
    }

    func setPaneStar(id: String, starred: Bool) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/panes/\(id)/star",
            method: "POST",
            body: StarBody(starred: starred)
        )
    }

    func retirePiPane(_ pane: HerdrPane, requestID: String) async throws -> PaneRetirementResponse {
        try await requirePaneRetirement()
        let response: PaneRetirementResponse = try await request(
            path: "/api/v1/panes/\(pane.paneID)/end-pi-and-close", method: "POST",
            body: PaneRetirementRequest(requestID: requestID, terminalID: pane.terminalID, sessionID: pane.piSemantic?.sessionID)
        )
        guard response.ok, response.closedPaneID == pane.paneID,
              response.workspaceID == pane.workspaceID, response.tabID == pane.tabID,
              !response.nextPaneID.isEmpty, response.nextPaneID != pane.paneID else { throw APIError.invalidResponse }
        return response
    }

    func openReservedShell(_ pane: HerdrPane, startPi: Bool) async throws {
        try await requirePaneRetirement()
        let response: MutationResponse = try await request(
            path: "/api/v1/panes/\(pane.paneID)/reserved-shell", method: "POST",
            body: ReservedShellRequest(terminalID: pane.terminalID, action: startPi ? "pi" : "shell")
        )
        guard response.ok else { throw APIError.invalidResponse }
    }

    private func requirePaneRetirement() async throws {
        let response = try await serverCapabilities()
        guard response.supportsRetirement else {
            throw APIError.server(status: 426, message: "Update the Companion server to close chats while keeping their tab. This pane was left open.")
        }
    }

    func closePane(id: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)", method: "DELETE", body: APIActionBody())
    }

    func promptPane(id: String, text: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/prompt", body: APIActionBody(text: text))
    }

    func sendText(toPane id: String, text: String, submit: Bool) async throws {
        if submit {
            try await runCommand(inPane: id, command: text)
        } else {
            try await mutation(path: "/api/v1/panes/\(id)/send-text", body: APIActionBody(text: text))
        }
    }

    func sendKeys(toPane id: String, keys: [String]) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/send-keys", body: APIActionBody(keys: keys))
    }

    func runCommand(inPane id: String, command: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/run", body: APIActionBody(command: command))
    }

    func startAgent(inPane id: String, name: String, kind: String) async throws {
        try await mutation(
            path: "/api/v1/panes/\(id)/start-agent",
            body: APIActionBody(kind: kind, name: name)
        )
    }

    func markAlertRead(id: String) async throws {
        try await mutation(path: "/api/v1/alerts/\(id)/read", body: APIActionBody())
    }

    func markAllAlertsRead() async throws {
        try await mutation(path: "/api/v1/alerts/read-all", body: APIActionBody())
    }

    func markPaneAlertsRead(paneID: String) async throws {
        try await mutation(path: "/api/v1/panes/\(paneID)/alerts/read", body: APIActionBody())
    }

    func registerPushDevice(
        token: String,
        bundleID: String,
        environment: String
    ) async throws -> Bool {
        let body = PushDeviceBody(
            deviceToken: token,
            bundleId: bundleID,
            environment: environment
        )
        let _: MutationResponse = try await request(
            path: "/api/v1/push/devices",
            method: "POST",
            body: body
        )
        let status: PushStatusResponse = try await request(path: "/api/v1/push/status")
        return status.apns.configured
    }

    func events(after lastEventID: Int? = nil) -> AsyncThrowingStream<HerdrEvent, any Error> {
        var request = makeRequest(path: "/api/v1/events", method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID {
            request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID")
        }
        let eventRequest = request
        let session = self.session

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: eventRequest)
                    try Self.validate(response: response)
                    var parser = HerdrSSEParser()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    throw APIError.streamEnded
                } catch {
                    if HerdrCancellation.isCancellation(error) {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func terminalEvents(
        paneID: String,
        columns: Int = 100,
        rows: Int = 32
    ) -> AsyncThrowingStream<TerminalStreamEvent, any Error> {
        var request = makeRequest(
            path: "/api/v1/panes/\(paneID)/stream",
            method: "GET",
            query: [
                URLQueryItem(name: "cols", value: String(columns)),
                URLQueryItem(name: "rows", value: String(rows)),
            ]
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let terminalRequest = request
        let session = self.session

        // Terminal deltas are order-dependent. A bounded oldest-first buffer
        // therefore aborts on overflow, forcing a full-frame resync instead of
        // silently applying a corrupted suffix of the stream.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: terminalRequest)
                    try Self.validate(response: response)
                    var parser = TerminalSSEParser()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = try parser.consume(line: line) {
                            HerdrPerfDiagnostics.streamBacklog.noteYielded(.terminal)
                            if case .dropped = continuation.yield(event) {
                                HerdrPerfDiagnostics.streamBacklog.noteOverflow(.terminal)
                                continuation.finish(throwing: APIError.streamBacklogOverflow)
                                return
                            }
                        }
                    }
                    throw APIError.streamEnded
                } catch {
                    if HerdrCancellation.isCancellation(error) {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func fetchPiConversationSnapshot(paneID: String) async throws -> PiConversationSnapshot {
        try await request(path: "/api/v1/panes/\(paneID)/pi/snapshot")
    }

    func fetchPiModels(paneID: String) async throws -> PiModelCatalogResponse {
        try await request(path: "/api/v1/panes/\(paneID)/pi/models")
    }

    func piConversationEvents(
        paneID: String,
        after cursor: String?
    ) -> AsyncThrowingStream<PiConversationStreamEvent, any Error> {
        let query = cursor.map { [URLQueryItem(name: "after", value: $0)] } ?? []
        var request = makeRequest(
            path: "/api/v1/panes/\(paneID)/pi/events",
            method: "GET",
            query: query
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let cursor, !cursor.isEmpty {
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
        }
        let eventRequest = request
        let session = self.session

        // Pi envelopes are order-dependent. A bounded oldest-first buffer
        // preserves a contiguous prefix on overflow so the store can resume
        // from its last applied cursor without dropping or double-applying a delta.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: eventRequest)
                    try Self.validate(response: response)
                    var parser = PiConversationSSEParser()

                    for try await line in bytes.lines {
                        os_signpost(.event, log: piStreamLog, name: "sse.line")
                        try Task.checkCancellation()
                        if let event = try parser.consume(line: line) {
                            HerdrPerfDiagnostics.streamBacklog.noteYielded(.pi)
                            if case .dropped = continuation.yield(event) {
                                HerdrPerfDiagnostics.streamBacklog.noteOverflow(.pi)
                                continuation.finish(throwing: APIError.streamBacklogOverflow)
                                return
                            }
                        }
                    }
                    throw APIError.streamEnded
                } catch {
                    if HerdrCancellation.isCancellation(error) {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func sendPiPrompt(
        paneID: String,
        text: String,
        disposition: PiPromptDisposition,
        waitForIdle: Bool = false
    ) async throws {
        let path: String
        switch disposition {
        case .prompt:
            path = "/api/v1/panes/\(paneID)/pi/prompt"
        case .steer:
            path = "/api/v1/panes/\(paneID)/pi/steer"
        case .followUp:
            path = "/api/v1/panes/\(paneID)/pi/follow-up"
        }
        let response: PiCommandResponse = try await request(
            path: path,
            method: "POST",
            body: APIActionBody(
                text: text,
                wait: waitForIdle ? true : nil,
                until: waitForIdle ? "idle" : nil,
                timeoutMs: waitForIdle ? 60_000 : nil
            )
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func ingestActiveWork(_ body: ActiveWorkIngestionBody) async throws {
        let response: MutationResponse = try await request(
            path: "/api/v1/active-work/ingestions",
            method: "POST",
            body: body
        )
        guard response.ok else { throw APIError.invalidResponse }
    }

    func abortPiConversation(paneID: String) async throws {
        let response: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/abort",
            method: "POST",
            body: APIActionBody()
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func compactPiConversation(paneID: String) async throws {
        let response: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/compact",
            method: "POST",
            body: APIActionBody()
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func setPiModel(paneID: String, provider: String, modelID: String) async throws {
        let response: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/model",
            method: "POST",
            body: PiSetModelBody(provider: provider, id: modelID)
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func setPiThinkingLevel(paneID: String, level: String) async throws -> String? {
        let response: PiSetThinkingLevelResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/thinking-level",
            method: "POST",
            body: PiSetThinkingLevelBody(level: level)
        )
        guard response.accepted else { throw APIError.invalidResponse }
        return response.level
    }

    func respondToPiInteraction(
        paneID: String,
        interactionID: String,
        response: PiInteractionResponseBody
    ) async throws {
        let safeInteractionID = interactionID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? interactionID
        let result: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/interactions/\(safeInteractionID)/respond",
            method: "POST",
            body: response
        )
        guard result.accepted else { throw APIError.invalidResponse }
    }

    private func mutation(
        path: String,
        method: String = "POST",
        body: APIActionBody
    ) async throws {
        let _: MutationResponse = try await request(path: path, method: method, body: body)
    }

    private func request<Response: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = makeRequest(path: path, method: "GET", query: query)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = makeRequest(path: path, method: method)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) -> URLRequest {
        var components = URLComponents(url: configuration.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query
            // URLQueryItem leaves literal plus signs unescaped. The companion's
            // form-style query decoder reads those as spaces, so preserve them
            // as data after URLQueryItem has encoded every other character.
            let percentEncodedQuery = components?.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            components?.percentEncodedQuery = percentEncodedQuery
        }
        var request = URLRequest(url: components?.url ?? configuration.baseURL)
        request.httpMethod = method
        request.timeoutInterval = Self.timeoutInterval(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func timeoutInterval(path: String, method: String) -> TimeInterval {
        if path.hasPrefix("/api/v1/pr-reviews/") && path.hasSuffix("/content") { return 600 }
        if path.hasPrefix("/api/v1/pr-reviews/") && path.hasSuffix("/documents") && method == "POST" { return 90 }
        if path.hasPrefix("/api/v1/pr-reviews") { return 30 }
        if path == "/api/v1/health" || path == "/api/v1/network" || path == "/api/v1/config/machines" {
            return 8
        }
        if path == "/api/v1/response-audio/capabilities" {
            return 8
        }
        if path.hasPrefix("/api/v1/agent-profiles") {
            return 30
        }
        if path.hasPrefix("/api/v1/response-audio/") {
            return 150
        }
        if path.hasSuffix("/end-pi-and-close") || path.hasSuffix("/reserved-shell") {
            return 75
        }
        if path == "/api/v1/quick-sessions/pi" {
            return 75
        }
        if path == "/api/v1/agent-runs", method == "POST" {
            return 90
        }
        if path == "/api/v1/issue-reports", method == "POST" {
            // The server uploads every attachment to GitHub and files the
            // issue before answering: up to five sequential `gh` calls of
            // 120 s each (labels, release view/create, upload, issue create).
            // Outlive that worst case — giving up earlier leaves an issue
            // the client never learns about, and "Try again" files it twice.
            return 600
        }
        if path == "/api/v1/fleet/sync" || path == "/api/v1/fleet/action" {
            // Sync can clone a missing catalog and action handlers may wait
            // for the managed command to finish. Keep the client alive for
            // the backend's long-running Fleet operations.
            return 150
        }
        if path == "/api/v1/agent-runs" || path.hasPrefix("/api/v1/agent-runs/") {
            return 30
        }
        if path.hasPrefix("/api/v1/result-artifacts/") && path.hasSuffix("/content") {
            return 10 * 60
        }
        if method != "GET", ["/send-text", "/send-keys", "/run"].contains(where: path.hasSuffix) {
            return 5
        }
        if method == "GET" && (path.hasSuffix("events") || path.hasSuffix("stream")) {
            return 24 * 60 * 60
        }
        if path.hasSuffix("/attachments") {
            // Uploads allow a full minute. Leave
            // headroom for the authenticated Herdr proxy hop as well.
            return 90
        }
        if path == "/api/v1/voice/transcriptions" {
            return 120
        }
        if path == "/api/v1/work-inbox" ||
            path.hasPrefix("/api/v1/active-work") ||
            path.hasPrefix("/api/v1/jira/") ||
            (path.hasPrefix("/api/v1/panes/") && path.contains("/git")) ||
            (path.hasPrefix("/api/v1/first-mate/features/") && path.contains("/git")) ||
            (path.hasPrefix("/api/v1/workspaces/") &&
                (path.contains("/git") || path.hasSuffix("/skills") || path.hasSuffix("/files"))) {
            // Git and Jira operations may run for up to 10 and 15
            // seconds respectively. The client must outlive the upstream call.
            return 30
        }
        return 15
    }

    private static func isValidResultArtifactID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy(allowed.contains) && id != "." && id != ".."
    }

    private static func validate(response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data).error.message) ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}

struct TerminalSSEParser {
    private var eventName = "message"
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    mutating func consume(line: String) throws -> TerminalStreamEvent? {
        if line.hasPrefix(":") {
            return .activity
        }
        if line.hasPrefix("event:") {
            if !dataLines.isEmpty { resetRecord() }
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            try enforceBufferLimit()
            return try dispatchIfComplete(force: false)
        }
        guard line.isEmpty else { return nil }
        return try dispatchIfComplete(force: true)
    }

    private mutating func dispatchIfComplete(force: Bool) throws -> TerminalStreamEvent? {
        guard !dataLines.isEmpty else {
            if force { resetRecord() }
            return nil
        }

        switch eventName {
        case "ready":
            resetRecord()
            return .ready
        case "heartbeat":
            resetRecord()
            return .activity
        case "terminal.frame":
            let payload = dataLines.joined(separator: "\n")
            guard let data = payload.data(using: .utf8) else {
                if force { resetRecord(); throw APIError.invalidResponse }
                return nil
            }
            guard let frame = try? decoder.decode(TerminalFrame.self, from: data) else {
                if force { resetRecord(); throw APIError.invalidResponse }
                return nil
            }
            resetRecord()
            return .frame(frame)
        case "terminal.error", "terminal.closed":
            resetRecord()
            throw APIError.streamEnded
        default:
            if force { resetRecord() }
            return nil
        }
    }

    private mutating func resetRecord() {
        eventName = "message"
        dataLines.removeAll(keepingCapacity: true)
    }

    private mutating func enforceBufferLimit() throws {
        guard dataLines.count <= 64,
              dataLines.reduce(0, { $0 + $1.lengthOfBytes(using: .utf8) + 1 }) <= 4 * 1024 * 1024
        else {
            resetRecord()
            throw APIError.invalidResponse
        }
    }
}

/// Cancels a URLSession download as soon as transport progress exceeds the
/// trusted metadata ceiling. The final response and on-disk size are checked
/// independently before the temporary file enters Herdr's cache.
private final class ResultArtifactDownloadLimiter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumByteCount: Int64
    private let lock = NSLock()
    private var _exceededLimit = false
    private var _failureStatus: Int?

    init(maximumByteCount: Int64) {
        self.maximumByteCount = maximumByteCount
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _exceededLimit
    }

    var failureStatus: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _failureStatus
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        _ = session
        _ = bytesWritten
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            lock.lock()
            _failureStatus = response.statusCode
            lock.unlock()
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > maximumByteCount
            || (totalBytesExpectedToWrite >= 0 && totalBytesExpectedToWrite > maximumByteCount) {
            lock.lock()
            _exceededLimit = true
            lock.unlock()
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        _ = session
        _ = downloadTask
        _ = location
    }
}

/// Parses Herdr's SSE records, which are either broker envelopes containing an
/// inner event payload or hand-written records whose JSON payload is the event data.
struct HerdrSSEParser {
    static let decodedEventNames: Set<String> = [
        "snapshot.updated", "alert.created", "alert.updated", "alerts.read_state_changed",
        "stars.changed", "push.delivery", "ready", "stream.reset", "cleanup.run_updated",
        "result_artifact.created",
        "pi.bridge.connection", "pi.session_start", "pi.session_shutdown", "pi.session_info_changed",
        "pi.session_tree", "pi.session_compact",
    ]

    private var eventName = "message"
    private var eventID: Int?
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    mutating func consume(line: String) -> HerdrEvent? {
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            if !dataLines.isEmpty { resetRecord() }
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("id:") {
            if !dataLines.isEmpty { resetRecord() }
            eventID = Int(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            if dataLines.count > 64 || dataLines.reduce(0, { $0 + $1.lengthOfBytes(using: .utf8) + 1 }) > 4 * 1024 * 1024 {
                resetRecord()
                return nil
            }
            return dispatchIfComplete(force: false)
        }
        guard line.isEmpty else { return nil }
        return dispatchIfComplete(force: true)
    }

    private mutating func dispatchIfComplete(force: Bool) -> HerdrEvent? {
        guard !dataLines.isEmpty else {
            if force { resetRecord() }
            return nil
        }

        let name = eventName
        let id = eventID
        if name != "message", !Self.decodedEventNames.contains(name) {
            resetRecord()
            return HerdrEvent(id: id, event: name, data: .null)
        }
        guard let data = dataLines.joined(separator: "\n").data(using: .utf8) else {
            if force { resetRecord() }
            return nil
        }
        if let value = try? decoder.decode(JSONValue.self, from: data) {
            let event: HerdrEvent
            if case let .object(object) = value,
               let innerData = object["data"],
               case let .string(innerName)? = object["event"] {
                let innerID: Int?
                if case let .number(number)? = object["id"] {
                    innerID = Int(number)
                } else {
                    innerID = nil
                }
                event = HerdrEvent(id: innerID ?? id, event: innerName, data: innerData)
            } else {
                let messageName: String?
                if case let .object(object) = value,
                   case let .string(innerName)? = object["event"] {
                    messageName = innerName
                } else {
                    messageName = nil
                }
                event = HerdrEvent(id: id, event: name == "message" ? (messageName ?? "message") : name, data: value)
            }
            resetRecord()
            return event
        }
        if force { resetRecord() }
        return nil
    }

    private mutating func resetRecord() {
        eventName = "message"
        eventID = nil
        dataLines.removeAll(keepingCapacity: true)
    }
}

private struct ServerErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }

    let error: Payload
}

private struct StarBody: Encodable, Sendable {
    let starred: Bool
}

private struct ResponseAudioPrepareBody: Encodable, Sendable {
    let action: ResponseAudioAction
    let text: String
}

private struct ResponseAudioSpeechBody: Encodable, Sendable {
    let text: String
}
