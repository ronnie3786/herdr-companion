import Foundation

/// Synthetic, process-local discussions used only by the app's explicit demo mode.
actor PRReviewDiscussionDemoClient: PRReviewDiscussionClient {
    @MainActor private static var clients: [String: PRReviewDiscussionDemoClient] = [:]
    @MainActor static func client(machineID: String) -> PRReviewDiscussionDemoClient {
        if let client = clients[machineID] { return client }
        let client = PRReviewDiscussionDemoClient()
        clients[machineID] = client
        return client
    }

    private var reviews: [String: [PRReviewDiscussion]] = [:]
    private var receipts: [String: PRReviewDiscussion] = [:]

    func prReviewDiscussions(reviewID: String) async throws -> [PRReviewDiscussion] {
        if let threads = reviews[reviewID] { return threads }
        let date = "2026-01-15T14:30:00Z"
        let threads: [PRReviewDiscussion] = reviewID == "prr_demo42" ? [
            PRReviewDiscussion(id: "demo-catalog-thread", reviewID: reviewID, state: "open",
                anchor: .init(path: "Sources/Catalog/SeedCatalog.swift", baseSHA: "base", headSHA: "head",
                    spans: [.init(side: .after, start: 2, end: 2)], codeExcerpt: "+struct SeedCatalog {}"),
                outdated: false, createdAt: date, updatedAt: date, version: 1,
                messages: [.init(id: "demo-catalog-message", author: "agent",
                    body: "Swift reviewer: How will an empty catalog be represented while sync is in progress? Consider an explicit loading state before adding the sync implementation.",
                    createdAt: date, updatedAt: date)],
                history: [.init(id: "demo-catalog-created", action: "created", author: "agent", createdAt: date, baseSHA: "base", headSHA: "head")])
        ] : []
        reviews[reviewID] = threads
        return threads
    }

    func createPRReviewDiscussion(reviewID: String, request: PRReviewDiscussionCreate) async throws -> PRReviewDiscussion {
        if let cached = receipts[request.requestID] { return cached }
        _ = try await prReviewDiscussions(reviewID: reviewID)
        let date = Date().ISO8601Format()
        let diff = await MainActor.run { PRReviewDemo.diff(for: reviewID) }
        let anchor = request.anchor.map {
            let selected = $0
            let lines = diff.files.first(where: { $0.path == selected.path })?.hunks.flatMap(\.lines) ?? []
            let excerpt = lines.filter { line in
                selected.spans.contains { span in
                    let number = span.side == .before ? line.oldNumber : line.newNumber
                    return number.map { $0 >= span.start && $0 <= span.end } ?? false
                }
            }.map { ($0.kind == "add" ? "+" : $0.kind == "del" ? "-" : " ") + $0.text }.joined(separator: "\n")
            return PRReviewDiscussionAnchor(path: selected.path, baseSHA: selected.baseSHA, headSHA: selected.headSHA, spans: selected.spans,
                codeExcerpt: excerpt, comparisonSelection: selected.comparison)
        }
        let thread = PRReviewDiscussion(id: UUID().uuidString, reviewID: reviewID, state: "open", anchor: anchor,
            outdated: false, createdAt: date, updatedAt: date, version: 1,
            messages: [.init(id: UUID().uuidString, author: request.author, body: request.body, createdAt: date, updatedAt: date)],
            history: [.init(id: UUID().uuidString, action: "created", author: request.author, createdAt: date,
                baseSHA: anchor?.baseSHA, headSHA: anchor?.headSHA)])
        reviews[reviewID, default: []].append(thread)
        receipts[request.requestID] = thread
        return thread
    }

    func replyToPRReviewDiscussion(reviewID: String, threadID: String, request: PRReviewDiscussionReply) async throws -> PRReviewDiscussion {
        if let cached = receipts[request.requestID] { return cached }
        let index = try index(reviewID: reviewID, threadID: threadID)
        let date = Date().ISO8601Format()
        var thread = reviews[reviewID]![index]
        thread.messages.append(.init(id: UUID().uuidString, author: request.author, body: request.body, createdAt: date, updatedAt: date))
        thread.history.append(.init(id: UUID().uuidString, action: "replied", author: request.author,
            createdAt: date, baseSHA: thread.anchor?.baseSHA, headSHA: thread.anchor?.headSHA))
        thread.updatedAt = date
        thread.version += 1
        reviews[reviewID]![index] = thread
        receipts[request.requestID] = thread
        return thread
    }

    func setPRReviewDiscussionState(reviewID: String, threadID: String, request: PRReviewDiscussionStateChange) async throws -> PRReviewDiscussion {
        if let cached = receipts[request.requestID] { return cached }
        let index = try index(reviewID: reviewID, threadID: threadID)
        var thread = reviews[reviewID]![index]
        guard thread.version == request.expectedVersion else {
            throw APIError.server(status: 409, message: "This thread changed. Reload before updating it.")
        }
        let date = Date().ISO8601Format()
        thread.state = request.state
        thread.version += 1
        thread.updatedAt = date
        thread.history.append(.init(id: UUID().uuidString, action: request.state == "resolved" ? "resolved" : "reopened",
            author: request.author, createdAt: date, baseSHA: thread.anchor?.baseSHA, headSHA: thread.anchor?.headSHA))
        reviews[reviewID]![index] = thread
        receipts[request.requestID] = thread
        return thread
    }

    private func index(reviewID: String, threadID: String) throws -> Int {
        guard let index = reviews[reviewID]?.firstIndex(where: { $0.id == threadID }) else { throw APIError.invalidResponse }
        return index
    }
}
