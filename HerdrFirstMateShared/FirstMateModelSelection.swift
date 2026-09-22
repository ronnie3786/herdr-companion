import Foundation

struct FirstMateModelSelection: Codable, Equatable, Sendable {
    var profile: String
    var requestedModel: String
    var requestedThinking: String
    var actualModel: String?
    var actualThinking: String?
    var source: String

    var compactDisplayName: String {
        if let actual = normalized(actualModel) {
            return joined(model: shortModel(actual), thinking: normalized(actualThinking))
        }
        let requested = normalized(requestedModel).map(shortModel) ?? "Pi default"
        return "Requested \(joined(model: requested, thinking: normalized(requestedThinking)))"
    }

    var fullDisplayName: String {
        if let actual = normalized(actualModel) {
            return "Actual \(joined(model: actual, thinking: normalized(actualThinking)))"
        }
        return "Requested \(joined(model: normalized(requestedModel) ?? "Pi default", thinking: normalized(requestedThinking)))"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shortModel(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
    }

    private func joined(model: String, thinking: String?) -> String {
        thinking.map { "\(model) · \($0)" } ?? model
    }

    enum CodingKeys: String, CodingKey {
        case profile, source
        case requestedModel = "requested_model", requestedThinking = "requested_thinking"
        case actualModel = "actual_model", actualThinking = "actual_thinking"
    }
}

struct FirstMateModelRouting: Decodable, Equatable, Sendable {
    var coordinator: FirstMateRoutingDefault
    var planning: FirstMateRoutingDefault
    var execution: FirstMateRoutingDefault
}

struct FirstMateRoutingDefault: Decodable, Equatable, Sendable {
    var model: String
    var thinking: String

    var compactDisplayName: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = trimmed.isEmpty ? "Pi default" : (trimmed.split(separator: "/").last.map(String.init) ?? trimmed)
        let effort = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return effort.isEmpty ? modelName : "\(modelName) · \(effort)"
    }
}
