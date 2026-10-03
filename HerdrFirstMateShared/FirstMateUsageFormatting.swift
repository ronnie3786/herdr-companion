import Foundation

enum FirstMateUsageFormatting {
    static func compactCost(_ usage: FirstMateUsage?) -> String {
        guard let usage, usage.status != "unavailable", let cost = validCost(usage.costUSD) else {
            return "Unavailable"
        }
        let amount = cost > 0 && cost < 0.01 ? "<$0.01" : currency(cost, code: usage.currency)
        return coverageLabels(usage).isEmpty ? amount : "\(amount)*"
    }

    static func cost(_ cost: Double?, currencyCode: String = "USD") -> String {
        guard let cost = validCost(cost) else { return "Unavailable" }
        if cost > 0, cost < 0.01 { return "Less than $0.01" }
        return currency(cost, code: currencyCode)
    }

    static func tokens(_ count: Int) -> String {
        max(0, count).formatted(.number.grouping(.automatic))
    }

    static func modelName(provider: String?, model: String?) -> String {
        let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        if let model, !model.isEmpty {
            let canonical = model.split(separator: "/").last.map(String.init) ?? model
            let known = ["gpt", "claude", "gemini", "qwen", "deepseek", "glm", "llama", "mistral", "o1", "o3", "o4"]
            return known.contains(where: { canonical.lowercased().hasPrefix($0) })
                ? PiModelDisplayName.short(provider: provider ?? "", modelID: model, name: nil)
                : canonical
        }
        #endif
        switch (provider?.isEmpty == false ? provider : nil, model?.isEmpty == false ? model : nil) {
        case let (.some(provider), .some(model)): return "\(provider) / \(model)"
        case let (.some(provider), nil): return provider
        case let (nil, .some(model)): return model
        case (nil, nil): return "Unknown model"
        }
    }

    static func modelNames(_ usage: FirstMateUsage?) -> String {
        guard let usage, !usage.models.isEmpty else { return "Unknown model" }
        return usage.models.map { modelName(provider: $0.provider, model: $0.model) }.joined(separator: ", ")
    }

    static func inlineSummary(_ usage: FirstMateUsage?) -> String {
        guard let usage else { return "Usage unavailable" }
        let compact = compactCost(usage)
        let estimate = compact == "Unavailable" ? "Usage unavailable" : "\(compact) estimated"
        let qualifiers = coverageLabels(usage).map { " · \($0)" }.joined()
        let tokenText = "\(tokens(usage.totalTokens)) tokens"
        return "\(estimate)\(qualifiers) · \(tokenText) · \(modelNames(usage))"
    }

    static func coverage(_ usage: FirstMateUsage) -> String {
        if usage.missingCostRecords > 0 {
            let records = usage.missingCostRecords == 1 ? "record" : "records"
            return "Cost coverage incomplete · \(usage.missingCostRecords) \(records) missing cost"
        }
        if usage.status != "complete" || usage.stale == true {
            return "Cost reported in \(usage.knownCostSessions) sessions · full coverage unverified"
        }
        let sessions = usage.sessionCount == 1 ? "session" : "sessions"
        return "\(usage.knownCostSessions) of \(usage.sessionCount) \(sessions) report cost"
    }

    static func coverageWarning(_ usage: FirstMateUsage) -> String? {
        if usage.stale == true {
            return "Showing the last reported total; the usage source is temporarily unreadable."
        }
        if usage.missingCostRecords > 0 {
            return "Some retained usage or cost records are unavailable."
        }
        if let count = usage.unaccountedRecords, count > 0 {
            let records = count == 1 ? "record could" : "records could"
            return "\(count) transcript \(records) not be checked. The total may understate actual usage."
        }
        if usage.status == "partial" {
            return "Full usage coverage could not be verified. The total may understate actual usage."
        }
        return nil
    }

    static func accessibilityDescription(_ usage: FirstMateUsage?) -> String {
        guard let usage else {
            return "Usage unavailable. This companion did not report usage; it may need an update."
        }
        let estimate: String
        if usage.status == "unavailable" || validCost(usage.costUSD) == nil {
            estimate = "Estimated USD cost unavailable"
        } else {
            estimate = "\(cost(usage.costUSD, currencyCode: usage.currency)) estimated USD reported by Pi"
        }
        var parts = [estimate, "\(tokens(usage.totalTokens)) tokens", coverage(usage)]
        if usage.status == "partial" { parts.append("Partial coverage") }
        if usage.stale == true { parts.append("Last reported value; source is temporarily unreadable") }
        if let warning = coverageWarning(usage) { parts.append(warning) }
        parts.append("This is not a provider invoice")
        return parts.joined(separator: ". ") + "."
    }

    static func taskAccessibilityDescription(_ usage: FirstMateUsage?) -> String {
        "Task total across all retained managed sessions. \(accessibilityDescription(usage))"
    }

    private static func coverageLabels(_ usage: FirstMateUsage) -> [String] {
        var labels: [String] = []
        if usage.status == "partial" { labels.append("Partial") }
        if usage.stale == true { labels.append("Last reported") }
        return labels
    }

    private static func validCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func currency(_ value: Double, code: String) -> String {
        value.formatted(
            .currency(code: code.isEmpty ? "USD" : code)
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "en_US"))
        )
    }
}
