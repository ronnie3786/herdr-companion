import SwiftUI

struct WatcherEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: WatchersStore
    var entry: WatcherEntry?
    @State private var machineID = ""
    @State private var name = ""
    @State private var summary = "{time}, I run {script:check.sh} and leave results in {inbox:your Watcher inbox}."
    @State private var timezone = TimeZone.current.identifier
    @State private var avatar = "gauge"
    @State private var scheduleKind = "interval"
    @State private var everyMinutes = 15
    @State private var at = "09:00"
    @State private var days = "all"
    @State private var cron = "0 9 * * 1-5"
    @State private var once = Date.now.addingTimeInterval(3600)
    @State private var missedRuns = "skip"
    @State private var steps: [EditableStep] = [.script(index: 1), .delivery(index: 2)]
    @State private var preview: [String: PiJSONValue] = [:]
    @State private var error: String?
    @State private var saving = false
    @State private var loading = true
    @State private var scriptsLoaded = false
    @State private var chooseAvatar = false
    @State private var requestID = UUID().uuidString
    private var client: (any WatchersClient)? { store.client(for: machineID) }
    private var hasAgent: Bool { steps.contains { $0.kind == "agent" } }
    private var schedule: [String: PiJSONValue] {
        // Preserve imported cron windows and day lists until the user edits their schedule.
        if let entry, !scheduleChanged(from: entry.watcher) { var value = entry.watcher.schedule; value.removeValue(forKey: "summary"); return value }
        switch scheduleKind {
        case "daily": return ["kind": .string("daily"), "at": .string(at), "days": days == "weekends" ? .array([.number(6), .number(7)]) : .string(days)]
        case "cron": return ["kind": .string("cron"), "expression": .string(cron)]
        case "once": return ["kind": .string("once"), "at": .string(ISO8601DateFormatter().string(from: once))]
        default: return ["kind": .string("interval"), "every_minutes": .number(Double(everyMinutes)), "days": days == "weekends" ? .array([.number(6), .number(7)]) : .string(days)]
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(entry == nil ? "Set up a watcher" : "Edit watcher").font(.headline); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("The basics") {
                            TextField("Watcher name", text: $name)
                            Picker("Runs on", selection: $machineID) { ForEach(store.sources.filter { store.enabledMachines.contains($0.machineID) }, id: \.machineID) { Text($0.machineName).tag($0.machineID) } }.disabled(entry != nil)
                            TextField("Time zone", text: $timezone).help("An IANA timezone, such as America/Chicago")
                            HStack { WatcherAvatar(avatar: avatar, size: 52); Button("Choose avatar") { chooseAvatar = true }; Button("Shuffle", systemImage: "shuffle") { avatar = (hasAgent ? WatcherAvatar.characters : WatcherAvatar.instruments).randomElement() ?? avatar } }.popover(isPresented: $chooseAvatar) { WatcherAvatarPicker(character: hasAgent, selection: $avatar) }
                        }
                        section("When to wake up") {
                            Picker("Schedule", selection: $scheduleKind) { Text("Every interval").tag("interval"); Text("Daily").tag("daily"); Text("Cron expression").tag("cron"); Text("Just once").tag("once") }
                            if scheduleKind == "interval" { Stepper("Every \(everyMinutes) minutes", value: $everyMinutes, in: 1...1440) }
                            if scheduleKind == "daily" { TextField("Time (HH:mm)", text: $at) }
                            if scheduleKind == "daily" || scheduleKind == "interval" { Picker("Days", selection: $days) { Text("Every day").tag("all"); Text("Weekdays").tag("weekdays"); Text("Weekends").tag("weekends") } }
                            if scheduleKind == "cron" { TextField("Minute hour day month weekday", text: $cron).font(.system(.body, design: .monospaced)) }
                            if scheduleKind == "once" { DatePicker("Run at", selection: $once) }
                            Picker("After a missed run", selection: $missedRuns) { Text("Skip it").tag("skip"); Text("Catch up once").tag("run_once") }
                            Text("If a run is already working, the next fire is skipped.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                            Button("Preview next runs") { Task { await loadPreview() } }
                            if let next = preview["next"]?.arrayValue {
                                Text(preview.text("summary")).font(.system(size: 12, weight: .medium))
                                ForEach(Array(next.enumerated()), id: \.offset) { _, value in if let date = WatchersDate.parse(value.stringValue) { Text(WatchersDate.display(date, timezone: timezone)).font(.caption).foregroundStyle(HerdrTheme.secondaryText) } }
                            }
                        }
                        section("In plain English") {
                            TextEditor(text: $summary).font(.system(size: 12)).frame(minHeight: 90).scrollContentBackground(.hidden)
                            WatcherSummaryView(markup: summary, schedule: preview.text("summary", fallback: "on your schedule"))
                            Text("Smart chips: {time}, {script:file.sh}, {agent:Sol}, {skill:name}, {gh:pull requests}, {slack:#channel}, {inbox:Watcher inbox}, {repo:project}, {pc:computer}.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                        }
                    }.textFieldStyle(.roundedBorder).padding(22)
                }.frame(minWidth: 360, idealWidth: 420, maxWidth: 480)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("How it runs").font(.headline); Spacer(); Menu("Add step") { Button("Script") { steps.append(.script(index: steps.count + 1)) }; Button("Check / gate") { steps.append(.gate(index: steps.count + 1, source: steps.first?.id ?? "step1")) }; Button("Agent") { steps.append(.agent(index: steps.count + 1)) }; Button("Deliver to inbox") { steps.append(.delivery(index: steps.count + 1)) } } }
                        ForEach($steps) { $step in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(step.kind.capitalized, systemImage: step.kind == "script" ? "terminal" : step.kind == "agent" ? "sparkles" : "tray").font(.system(size: 12, weight: .semibold))
                                    Spacer(); Button("Move up", systemImage: "arrow.up") { moveStep(step.id, by: -1) }.labelStyle(.iconOnly); Button("Move down", systemImage: "arrow.down") { moveStep(step.id, by: 1) }.labelStyle(.iconOnly); Button("Remove", systemImage: "trash") { steps.removeAll { $0.id == step.id } }.labelStyle(.iconOnly)
                                }
                                TextField("Step title", text: $step.title)
                                if step.kind == "script" {
                                    TextField("Script filename", text: $step.file)
                                    TextField("Interpreter", text: $step.interpreter)
                                    Text("Script body").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                                    TextEditor(text: $step.content).font(.system(size: 11, design: .monospaced)).frame(minHeight: 150).scrollContentBackground(.hidden).padding(8).background(HerdrTheme.codeFill, in: .rect(cornerRadius: 8))
                                } else {
                                    WatcherStepSettings(step: $step, previousSteps: Array(steps.prefix { $0.id != step.id }))
                                }
                                DisclosureGroup("Advanced step settings") {
                                    TextEditor(text: $step.json).font(.system(size: 11, design: .monospaced)).frame(minHeight: 120).scrollContentBackground(.hidden)
                                    Text("Optional fields include timeout_seconds, cwd, icon and note. Instructions and delivery settings are preserved when you save.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                                }
                            }.padding(16).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 12))
                        }
                        Text("Save creates a draft. Unsupported step types can be drafted, but the companion checks executable capabilities before activation.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }.padding(22).textFieldStyle(.roundedBorder)
                }.frame(minWidth: 420, maxWidth: .infinity)
            }
            Divider()
            HStack { if let error { Text(error).font(.caption).foregroundStyle(.pink).lineLimit(3).textSelection(.enabled) }; Spacer(); if saving || loading { ProgressView().controlSize(.small) }; Button(entry == nil ? "Save draft" : "Save changes") { Task { await save() } }.buttonStyle(.borderedProminent).tint(HerdrTheme.accent).disabled(saving || loading || !scriptsLoaded || name.trimmingCharacters(in: .whitespaces).isEmpty || steps.isEmpty || client == nil) }.padding(18)
        }.frame(width: 1000, height: 740).herdrPaneBackground().task { await load() }
        .onChange(of: hasAgent) { _, agent in avatar = (agent ? WatcherAvatar.characters : WatcherAvatar.instruments).first ?? "gauge" }
    }
    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 13, weight: .semibold)); content() } }
    private func moveStep(_ id: String, by delta: Int) { guard let index = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(index + delta) else { return }; steps.swapAt(index, index + delta) }
    private func load() async {
        machineID = entry?.machineID ?? store.sources.first(where: { store.enabledMachines.contains($0.machineID) })?.machineID ?? ""
        defer { loading = false }
        guard let w = entry?.watcher else { scriptsLoaded = true; return }
        name = w.name; summary = w.summary; timezone = w.timezone; avatar = w.avatar; missedRuns = w.fields.text("missed_runs", fallback: "skip")
        scheduleKind = w.schedule.text("kind", fallback: "interval"); everyMinutes = max(1, Int(w.schedule.number("every_minutes"))); at = w.schedule.text("at", fallback: "09:00"); days = w.schedule.text("days", fallback: "all"); cron = w.schedule.text("expression"); once = WatchersDate.parse(w.schedule["at"]?.stringValue) ?? once
        steps = w.steps.map(EditableStep.init)
        guard let client else { return }
        do {
            for index in steps.indices where steps[index].kind == "script" { let value = try await client.watchersGet([w.id, "scripts", steps[index].id]); steps[index].content = value["script"]?.objectValue?.text("content") ?? value.text("content") }
            scriptsLoaded = true
            await loadPreview()
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleChanged(from w: Watcher) -> Bool { scheduleKind != w.schedule.text("kind") || (scheduleKind == "interval" && everyMinutes != Int(w.schedule.number("every_minutes"))) || (scheduleKind == "daily" && at != w.schedule.text("at")) || (scheduleKind == "cron" && cron != w.schedule.text("expression")) || days != w.schedule.text("days", fallback: "all") || (scheduleKind == "once" && abs(once.timeIntervalSince(WatchersDate.parse(w.schedule["at"]?.stringValue) ?? once)) > 1) }
    private func loadPreview() async {
        guard let client else { return }
        do { preview = try await client.watchersRequest(["schedule", "preview"], method: "POST", body: ["schedule": .object(schedule), "timezone": .string(timezone), "count": .number(3)], query: []); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let client else { return }; saving = true; defer { saving = false }
        do {
            var definition = entry?.watcher.definition ?? [:]
            definition.merge(["name": .string(name), "summary": .string(summary), "timezone": .string(timezone), "avatar": .string(avatar), "schedule": .object(schedule), "missed_runs": .string(missedRuns), "overlap": .string("skip"), "steps": .array(try steps.map { .object(try $0.definition()) })]) { _, value in value }
            var body: [String: PiJSONValue] = ["definition": .object(definition), "scripts": .object(Dictionary(uniqueKeysWithValues: steps.filter { $0.kind == "script" }.map { ($0.id, .string($0.content)) }))]
            if let entry { body["expected_revision"] = .number(Double(entry.watcher.revision)) }
            _ = try await client.watchersMutate(entry.map { [$0.watcher.id] } ?? [], method: entry == nil ? "POST" : "PATCH", body: body, requestID: requestID)
            await store.refresh(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
private struct EditableStep: Identifiable {
    var id: String
    var kind: String
    var title: String
    var file = ""
    var interpreter = "/bin/bash"
    var content = ""
    var json = "{}"
    var original: [String: PiJSONValue] = [:]
    init(_ step: WatcherStep) { id = step.id; kind = step.kind; title = step.title; file = step.file; interpreter = step.fields.text("interpreter", fallback: "/bin/bash"); original = step.fields; json = Self.pretty(step.fields) }
    private init(id: String, kind: String, title: String, file: String = "", json: [String: PiJSONValue] = [:]) { self.id = id; self.kind = kind; self.title = title; self.file = file; self.json = Self.pretty(json) }
    static func script(index: Int) -> Self { .init(id: "step\(index)-" + UUID().uuidString.prefix(6), kind: "script", title: "Run a script", file: index == 1 ? "check.sh" : "check\(index).sh") }
    static func gate(index: Int, source: String) -> Self { .init(id: "step\(index)-" + UUID().uuidString.prefix(6), kind: "gate", title: "Continue when something changes", json: ["rule": .object(["kind": .string("changed"), "from": .string(source)])]) }
    static func agent(index: Int) -> Self { .init(id: "step\(index)-" + UUID().uuidString.prefix(6), kind: "agent", title: "Review what changed", json: ["model": .string("openai-codex/gpt-6-sol"), "instructions": .string("Summarize the new information and identify anything that needs attention."), "timeout_seconds": .number(1800)]) }
    static func delivery(index: Int) -> Self { .init(id: "step\(index)-" + UUID().uuidString.prefix(6), kind: "deliver", title: "Leave the result in Watcher inbox", json: ["to": .array([.object(["kind": .string("inbox")])])]) }
    func definition() throws -> [String: PiJSONValue] {
        var result = try JSONDecoder().decode([String: PiJSONValue].self, from: Data(json.utf8))
        result["id"] = .string(id); result["kind"] = .string(kind); result["title"] = .string(title)
        if kind == "script" { result["file"] = .string(file); result["interpreter"] = .string(interpreter); if result["timeout_seconds"] == nil { result["timeout_seconds"] = .number(3600) } }
        return result
    }
    static func pretty(_ value: [String: PiJSONValue]) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}" }
}

private struct WatcherStepSettings: View {
    @Binding var step: EditableStep
    var previousSteps: [EditableStep]
    private var fields: [String: PiJSONValue] { (try? JSONDecoder().decode([String: PiJSONValue].self, from: Data(step.json.utf8))) ?? [:] }
    private func text(_ key: String, nested: String? = nil) -> Binding<String> {
        Binding(get: { nested.map { fields[$0]?.objectValue?.text(key) ?? "" } ?? fields.text(key) }, set: { value in
            var result = fields
            if let nested { var child = result[nested]?.objectValue ?? [:]; if value.isEmpty { child.removeValue(forKey: key) } else { child[key] = .string(value) }; result[nested] = .object(child) }
            else if value.isEmpty { result.removeValue(forKey: key) } else { result[key] = .string(value) }
            step.json = EditableStep.pretty(result)
        })
    }
    var body: some View {
        if step.kind == "agent" {
            TextField("Model", text: text("model"))
            TextField("Skill (optional)", text: text("skill"))
            Text("Instructions").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
            TextEditor(text: text("instructions")).font(.system(size: 12)).frame(minHeight: 110).scrollContentBackground(.hidden)
            Text("An agent step can stay in a draft until this companion supports agent execution.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
        } else if step.kind == "gate" {
            Picker("Continue when", selection: text("kind", nested: "rule")) { Text("The result changed").tag("changed"); Text("Items are new or updated").tag("new_items") }
            Picker("Result from", selection: text("from", nested: "rule")) { ForEach(previousSteps) { Text($0.title).tag($0.id) } }
            if fields["rule"]?.objectValue?.text("kind") == "new_items" { TextField("Unique item key (for example, id)", text: text("key", nested: "rule")); TextField("Version key (optional)", text: text("version", nested: "rule")) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((fields["to"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, value in
                    if let target = value.objectValue { Label(target.text("kind") == "inbox" ? "Watcher inbox" : target.text("target", fallback: target.text("kind")), systemImage: target.text("kind") == "inbox" ? "tray" : "paperplane").font(.system(size: 12)) }
                }
                Text("Inbox delivery is available. External destinations can be drafted in Advanced step settings when the companion supports them.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
            }
        }
    }
}
