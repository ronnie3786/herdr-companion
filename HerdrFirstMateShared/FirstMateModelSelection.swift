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
        guard !isUnconfiguredArchitectRequest else { return "Not configured" }
        let requested = normalized(requestedModel).map(shortModel) ?? "Pi default"
        return "Requested \(joined(model: requested, thinking: normalized(requestedThinking)))"
    }

    var profileDisplayName: String {
        normalized(profile) ?? "Unknown"
    }

    var requestedDisplayName: String {
        guard !isUnconfiguredArchitectRequest else { return "Not configured" }
        return joined(model: normalized(requestedModel) ?? "Pi default", thinking: normalized(requestedThinking))
    }

    var actualDisplayName: String {
        guard let actual = normalized(actualModel) else {
            return "Unavailable — no observed runtime evidence"
        }
        return joined(model: actual, thinking: normalized(actualThinking))
    }

    var fullDisplayName: String {
        "Profile: \(profileDisplayName) · Requested: \(requestedDisplayName) · Actual: \(actualDisplayName)"
    }

    private var isUnconfiguredArchitectRequest: Bool {
        normalized(profile)?.lowercased() == "architect" && normalized(requestedModel) == nil
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
    var architect: FirstMateRoutingDefault?
}

struct FirstMateRoutingDefault: Decodable, Equatable, Sendable {
    var model: String
    var thinking: String

    var compactDisplayName: String {
        if let configuredDisplayName { return configuredDisplayName }
        let effort = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return effort.isEmpty ? "Pi default" : "Pi default · \(effort)"
    }

    var configuredDisplayName: String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let modelName = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let effort = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return effort.isEmpty ? modelName : "\(modelName) · \(effort)"
    }

    var pinnedDisplayName: String {
        configuredDisplayName ?? "NOT CONFIGURED"
    }
}
