import Foundation

/// Preserves additive fields when an older Mac edits a newer draft.
struct Watcher: Codable, Equatable, Identifiable, Sendable {
    var fields: [String: PiJSONValue]
    init(_ fields: [String: PiJSONValue]) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try [String: PiJSONValue](from: decoder) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var id: String { fields.text("id") }
    var name: String { fields.text("name") }
    var summary: String { fields.text("summary") }
    var state: String { fields.text("state", fallback: "draft") }
    var avatar: String { fields.text("avatar", fallback: "gauge") }
    var revision: Int { Int(fields.number("revision")) }
    var timezone: String { fields.text("timezone", fallback: TimeZone.current.identifier) }
    var schedule: [String: PiJSONValue] { fields["schedule"]?.objectValue ?? [:] }
    var scheduleSummary: String { schedule.text("summary", fallback: fields.text("schedule_summary", fallback: "on a custom schedule")) }
    var steps: [WatcherStep] { fields["steps"]?.arrayValue?.compactMap { $0.objectValue.map(WatcherStep.init) } ?? [] }
    var kind: String { fields.text("kind", fallback: steps.contains { $0.kind == "agent" } ? (steps.contains { $0.kind == "script" } ? "hybrid" : "agent") : "script") }
    var live: [String: PiJSONValue]? { fields["live"]?.objectValue }
    var attention: String? { fields["attention"]?.objectValue?["reason"]?.stringValue }
    var nextFire: Date? { WatchersDate.parse(fields["next_fire_at"]?.stringValue) }
    var runsCount: Int { Int(fields.number("runs_count")) }
    var resting: Bool { state == "paused" || state == "done" }
    var status: String {
        if live != nil { return "Working now" }
        if state == "draft" { return "Draft, not scheduled yet" }
        if state == "paused" { return "Resting" }
        if state == "done" { return "All done" }
        if attention != nil { return "Needs you" }
        return schedule.text("kind") == "once" ? "One-time task" : "On watch"
    }
    var definition: [String: PiJSONValue] {
        if let value = fields["definition"]?.objectValue { return value }
        let readonly: Set<String> = ["id", "revision", "state", "machine", "live", "attention", "next_fire_at", "runs_count", "kind", "created_at", "updated_at", "activated_by", "activated_via", "last_run", "schedule_summary", "summary_tokens", "summary_text", "warnings", "source", "edit_target_id", "edit_target_revision", "edit_expected_revision"]
        var value = fields.filter { !readonly.contains($0.key) }
        var schedule = self.schedule; schedule.removeValue(forKey: "summary")
        value["schedule"] = .object(schedule)
        return value
    }
}
struct WatcherStep: Identifiable, Equatable, Sendable {
    var fields: [String: PiJSONValue]
    var id: String { fields.text("id") }
    var kind: String { fields.text("kind") }
    var title: String { fields.text("title", fallback: kind.capitalized) }
    var file: String { fields.text("file") }
    var symbol: String { switch kind { case "script": "terminal"; case "gate": "line.3.horizontal.decrease.circle"; case "agent": "sparkles"; default: "tray" } }
}
struct WatcherEntry: Identifiable, Equatable, Sendable {
    let machineID: String
    let machineName: String
    var watcher: Watcher
    var id: String { machineID + ":" + watcher.id }
}
struct WatcherRun: Identifiable, Sendable {
    var fields: [String: PiJSONValue]
    var id: String { fields.text("id", fallback: fields.text("run_id")) }
    var status: String { fields.text("status") }
    var label: String { switch status { case "finished": "Finished"; case "nothing_new": "Nothing new"; case "failed", "unknown": "Needs attention"; case "stopped": "Stopped"; case "running": "Working now"; default: "Queued" } }
    var summary: String { fields.text("summary") }
    var steps: [[String: PiJSONValue]] { (fields["step_runs"] ?? fields["steps"])?.arrayValue?.compactMap(\.objectValue) ?? [] }
}
enum WatchersDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func relative(_ date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes < 1 { return "soon" }; if minutes < 60 { return "in \(minutes) min" }; if minutes < 1440 { return "in \(minutes / 60) hr" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
extension Dictionary where Key == String, Value == PiJSONValue {
    func text(_ key: String, fallback: String = "") -> String { self[key]?.stringValue ?? fallback }
    func number(_ key: String) -> Double { if case let .number(value)? = self[key] { return value }; return 0 }
    func flag(_ key: String) -> Bool { if case let .bool(value)? = self[key] { return value }; return false }
}

extension WatchersDate {
    static func display(_ date: Date, timezone: String) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timezone)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date) + " · " + (formatter.timeZone.abbreviation(for: date) ?? timezone)
    }
}
