import Foundation

enum AgentControlRegistry {
    /// Mutations agents may never perform regardless of the global toggle.
    /// Tab colors are the user's personal organization data and the companion
    /// contract keeps them read-only.
    static let permanentlyDisabledActions: [String: String] = [
        "chat.tab-color": "Tab colors are read-only through agent control; edit them in the app.",
    ]

    private static let emptySchema: [String: PiJSONValue] = [
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ]

    static func actions(enabled: Bool, disabledReason: String? = nil) -> [AgentControlActionDescriptor] {
        [
            descriptor("ui.open", "Open exact target", schema: schema(properties: [
                "view": enumString(["chat", "terminal", "git", "skills"]),
                "inspector": enumString(["overview", "agents", "documents", "workflow"]),
            ]), targetKinds: ["pane", "workspace", "tab", "first-mate", "hud-chat"], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.segment", "Open app segment", schema: schema(properties: [
                "segment": enumString(["chat", "terminal", "git", "skills", "workspace", "active-work", "pr-review", "first-mate", "fleet", "attention", "activity"]),
            ], required: ["segment"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.back", "Go back", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.forward", "Go forward", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.refresh", "Refresh fleet", schema: emptySchema, targetKinds: [], effect: "read", enabled: enabled, reason: disabledReason),
            descriptor("ui.reveal", "Reveal target in sidebar", schema: emptySchema, targetKinds: ["pane"], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.settings", "Open Settings", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.hud", "Open HUD", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.notes", "Open HUD notes", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("ui.sidebar", "Configure sidebar", schema: schema(properties: [
                "filter": enumString(["all", "attention", "active"]),
                "recency": enumString(["today", "last3Days", "thisWeek", "all", "recents"]),
                "query": ["type": .string("string")],
            ]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("chat.summarize", "Open Pi session summary", schema: emptySchema, targetKinds: ["pane"], effect: "read", enabled: enabled, reason: disabledReason),
            descriptor("chat.smart-rename", "Smart rename chat", schema: emptySchema, targetKinds: ["pane"], effect: "mutation", enabled: enabled, reason: disabledReason),
            descriptor("chat.mark-unread", "Mark chat unread", schema: emptySchema, targetKinds: ["pane"], effect: "mutation", enabled: enabled, reason: disabledReason),
            descriptor("chat.tab-color", "Set tab color", schema: schema(properties: [
                "color": enumString(ChatTabColor.allCases.map(\.rawValue) + ["none"]),
            ], required: ["color"]), targetKinds: ["pane", "tab"], effect: "mutation", enabled: enabled, reason: disabledReason),
            descriptor("chat.set-model", "Set exact Pi model", schema: schema(properties: [
                "provider": ["type": .string("string")],
                "modelId": ["type": .string("string")],
            ], required: ["provider", "modelId"]), targetKinds: ["pane"], effect: "mutation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.open", "Open PR review", schema: schema(properties: ["review_id": stringRule(), "tab": enumString(["files","context","agents","skills"])], required:["review_id"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.select-file", "Select PR review file", schema: schema(properties:["path":stringRule()],required:["path"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.scroll-to-line", "Scroll to PR review line", schema: schema(properties:["path":stringRule(),"line":integerRule(),"side":enumString(["before","after"])],required:["path","line"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.highlight-lines", "Highlight PR review lines", schema: schema(properties:["path":stringRule(),"start":integerRule(),"end":integerRule(),"side":enumString(["before","after"])],required:["path","start","end"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.clear-highlight", "Clear PR review highlight", schema: emptySchema, targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.set-filter", "Set PR review filter", schema: schema(properties:["impact":enumString(["all","high","medium","low","unranked"])],required:["impact"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.set-view-mode", "Set PR review view mode", schema: schema(properties:["mode":enumString(["github","guided"])],required:["mode"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.set-tab", "Set PR review tab", schema: schema(properties:["tab":enumString(["files","context","agents","skills"])],required:["tab"]), targetKinds: [], effect: "navigation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.set-viewed", "Set PR review viewed state", schema: schema(properties:["path":stringRule(),"viewed":booleanRule()],required:["path","viewed"]), targetKinds: [], effect: "mutation", enabled: enabled, reason: disabledReason),
            descriptor("pr-review.state", "Read PR review state", schema: emptySchema, targetKinds: [], effect: "read", enabled: enabled, reason: disabledReason),
        ]
        .map { descriptor in
            guard let reason = permanentlyDisabledActions[descriptor.id] else { return descriptor }
            var copy = descriptor
            copy.enabled = false
            copy.disabledReason = reason
            return copy
        }
    }

    static func validate(action: String, parameters: [String: PiJSONValue]) throws {
        guard let descriptor = actions(enabled: true).first(where: { $0.id == action }) else {
            throw AgentControlCommandError.invalid("Unsupported action: \(action)")
        }
        guard descriptor.enabled else { throw AgentControlCommandError.disabled(descriptor.disabledReason ?? "Action is disabled.") }
        guard case let .object(properties)? = descriptor.parameters["properties"] else {
            throw AgentControlCommandError.invalid("Action schema is invalid.")
        }
        let required: Set<String>
        if case let .array(values)? = descriptor.parameters["required"] {
            required = Set(values.compactMap(\.stringValue))
        } else {
            required = []
        }
        let extras = Set(parameters.keys).subtracting(properties.keys)
        guard extras.isEmpty else {
            throw AgentControlCommandError.invalid("Unexpected parameter: \(extras.sorted().joined(separator: ", "))")
        }
        let missing = required.subtracting(parameters.keys)
        guard missing.isEmpty else {
            throw AgentControlCommandError.invalid("Missing parameter: \(missing.sorted().joined(separator: ", "))")
        }
        for (key, value) in parameters {
            let type = (properties[key].flatMap { rule -> String? in if case let .object(values) = rule { return values["type"]?.stringValue }; return nil }) ?? "string"
            switch type { case "string": guard case .string = value else { throw AgentControlCommandError.invalid("Parameter \(key) must be a string.") }; case "integer": guard case let .number(number) = value, number.rounded() == number, abs(number) <= 1_000_000 else { throw AgentControlCommandError.invalid("Parameter \(key) must be an integer.") }; case "boolean": guard case .bool = value else { throw AgentControlCommandError.invalid("Parameter \(key) must be a boolean.") }; default: throw AgentControlCommandError.invalid("Parameter \(key) has an invalid schema.") }
            if case let .object(rule)? = properties[key], case let .array(allowed)? = rule["enum"],
               !allowed.contains(value) {
                throw AgentControlCommandError.invalid("Parameter \(key) has an unsupported value.")
            }
            if key == "query", let text = value.stringValue, text.count > 500 {
                throw AgentControlCommandError.invalid("Sidebar query is too long.")
            }
            if ["provider", "modelId"].contains(key),
               let text = value.stringValue,
               text.isEmpty || text.count > 200 || text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                throw AgentControlCommandError.invalid("Parameter \(key) is invalid.")
            }
        }
    }

    private static func descriptor(
        _ id: String,
        _ title: String,
        schema: [String: PiJSONValue],
        targetKinds: [String],
        effect: String,
        enabled: Bool,
        reason: String?
    ) -> AgentControlActionDescriptor {
        AgentControlActionDescriptor(
            id: id,
            title: title,
            parameters: schema,
            targetKinds: targetKinds,
            effect: effect,
            enabled: enabled,
            disabledReason: enabled ? nil : reason
        )
    }

    private static func schema(
        properties: [String: [String: PiJSONValue]],
        required: [String] = []
    ) -> [String: PiJSONValue] {
        var result: [String: PiJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties.mapValues { .object($0) }),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { result["required"] = .array(required.map(PiJSONValue.string)) }
        return result
    }

    private static func enumString(_ values: [String]) -> [String: PiJSONValue] {
        [
            "type": .string("string"),
            "enum": .array(values.map(PiJSONValue.string)),
        ]
    }
    private static func stringRule() -> [String: PiJSONValue] { ["type": .string("string")] }
    private static func integerRule() -> [String: PiJSONValue] { ["type": .string("integer")] }
    private static func booleanRule() -> [String: PiJSONValue] { ["type": .string("boolean")] }
}
