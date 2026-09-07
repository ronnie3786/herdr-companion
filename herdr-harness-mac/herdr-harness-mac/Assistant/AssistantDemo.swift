#if DEBUG
import Foundation

@MainActor
final class AssistantDemo {
    private var runs: [String: HeadlessAgentRun] = [:]
    var transport: AssistantTransport {
        AssistantTransport(
            capabilities: { AssistantCapabilities(profiles: ["contextual-question-v1"]) },
            start: { request in
                let id = "agr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
                let data = try JSONSerialization.data(withJSONObject: [
                    "id": id, "status": "completed", "prompt": request.prompt,
                    "response": "This demo answer uses the context attached to your question. **Inspect Context** to see the captured source, or add another excerpt before a follow-up. No commands were executed.",
                    "createdAt": Date.now.ISO8601Format(), "threadRootRunId": request.continueFromRunId ?? id,
                ])
                let run = try JSONDecoder().decode(HeadlessAgentRun.self, from: data)
                self.runs[id] = run
                return run
            },
            fetch: { id in guard let run = self.runs[id] else { throw URLError(.resourceUnavailable) }; return run },
            stop: { id in guard let run = self.runs[id] else { throw URLError(.resourceUnavailable) }; return run },
            models: { throw URLError(.resourceUnavailable) },
            promote: { _ in throw APIError.server(status: 409, message: "Agent handoff is available when connected to a real companion.") },
            openAgent: { _ in }
        )
    }
}
#endif
