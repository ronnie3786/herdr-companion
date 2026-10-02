import SwiftUI

struct WatcherBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: WatchersStore
    var entry: WatcherEntry?
    @State private var machineID = ""
    @State private var sessionID = ""
    @State private var session: [String: PiJSONValue] = [:]
    @State private var prompt = ""
    @State private var sending = false
    @State private var error: String?
    @State private var showAvatars = false
    @State private var pendingRequestID = UUID().uuidString
    @State private var schedulePreview: [String: PiJSONValue] = [:]
    @State private var scriptStep: WatcherStep?
    @State private var runEntry: WatcherEntry?
    @State private var initialRunID: String?
    @State private var dryRunRequestID = UUID().uuidString
    @State private var createRequestID = UUID().uuidString
    @State private var creationRequestID = UUID().uuidString
    private var client: (any WatchersClient)? { store.client(for: machineID) }
    private var draft: Watcher? { session["draft"]?.objectValue.map(Watcher.init) }
    private var working: Bool { ["running", "working", "starting", "queued"].contains(session.text("status")) }
    private var machineName: String { store.sources.first { $0.machineID == machineID }?.machineName ?? "Companion" }
    private var messages: [[String: PiJSONValue]] { session["messages"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
    init(store: WatchersStore, entry: WatcherEntry?, initialSnapshot: [String: PiJSONValue] = [:]) {
        self.store = store; self.entry = entry; _session = State(initialValue: initialSnapshot)
        _machineID = State(initialValue: entry?.machineID ?? store.sources.first(where: { store.enabledMachines.contains($0.machineID) })?.machineID ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(entry == nil ? "Create a watcher" : "Edit with an agent", systemImage: "sparkles").font(.headline)
                Spacer()
                Picker("Runs on", selection: $machineID) { ForEach(store.sources.filter { store.enabledMachines.contains($0.machineID) }, id: \.machineID) { Text($0.machineName).tag($0.machineID) } }.frame(width: 230).disabled(!sessionID.isEmpty || sending)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if messages.isEmpty {
                                HStack(spacing: 10) { FirstMateFaceOrb(size: 38); Text("What should I keep an eye on?").font(.title3) }
                                Text("Tell me what to check, when to check it, and where the results should go. I'll ask about anything unclear and prepare a draft for you to review.").font(.system(size: 13)).foregroundStyle(HerdrTheme.secondaryText)
                                ForEach(["Check repository health every morning and put a summary in my Watcher inbox.", "Run my maintenance script every night at 1 AM."], id: \.self) { example in Button(example) { prompt = example }.buttonStyle(.herdrPlain).font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 8)) }
                            }
                            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(message.text("role") == "user" ? "You" : "Watcher builder").font(.system(size: 10, weight: .semibold)).foregroundStyle(HerdrTheme.accent)
                                    WatcherSummaryView(markup: message.text("text", fallback: message.text("content")), schedule: draft?.scheduleSummary ?? "on your schedule")
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(message.text("role") == "user" ? HerdrTheme.selectedFill : HerdrTheme.cardFill, in: .rect(cornerRadius: 12))
                            }
                            ForEach(Array((session["tools"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, tool in
                                if let tool = tool.objectValue { DisclosureGroup { Text(tool.text("output")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } label: { Label(tool.text("title", fallback: tool.text("name", fallback: "Working")), systemImage: tool.text("status") == "failed" ? "exclamationmark.circle" : "terminal").font(.system(size: 11)) }.foregroundStyle(HerdrTheme.secondaryText) }
                            }
                            if working || sending { ProgressView("Preparing your watcher…").controlSize(.small) }
                        }.padding(20)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.pink).padding(.horizontal, 20) }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Describe a watcher, or refine this draft…", text: $prompt, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).font(.system(size: 13))
                        Button { Task { await send() } } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)) }.buttonStyle(.borderedProminent).tint(HerdrTheme.controlAccent).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || working || client == nil).help("Send to the watcher builder")
                    }.padding(14).background(HerdrTheme.fieldFill, in: .rect(cornerRadius: 12)).padding([.horizontal, .bottom], 20)
                }.frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let draft {
                            WatcherCard(entry: .init(machineID: machineID, machineName: machineName, watcher: draft), preview: true).frame(maxWidth: 340).frame(maxWidth: .infinity)
                            HStack { Button("Shuffle", systemImage: "shuffle") { Task { await setAvatar((draft.kind == "script" ? WatcherAvatar.instruments : WatcherAvatar.characters).randomElement() ?? draft.avatar) } }; Button("Choose", systemImage: "square.grid.2x2") { showAvatars = true } }.buttonStyle(.bordered).font(.caption).disabled(working || sending || draft.state != "draft")
                                .popover(isPresented: $showAvatars) { WatcherAvatarPicker(character: draft.kind != "script", selection: Binding(get: { draft.avatar }, set: { value in showAvatars = false; Task { await setAvatar(value) } })) }
                            WatcherPipeline(watcher: draft, inspectScript: { scriptStep = $0 })
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Next runs").font(.system(size: 13, weight: .semibold))
                                ForEach(Array((schedulePreview["next"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, value in
                                    if let date = WatchersDate.parse(value.stringValue) { Text(WatchersDate.display(date, timezone: draft.timezone)).font(.caption).foregroundStyle(HerdrTheme.secondaryText) }
                                }
                            }
                            Text("Review the schedule, instructions and scripts before creating. Watcher inbox delivery is suppressed during a dry run. Scripts still execute and can contact external services.").font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText)
                        } else {
                            ContentUnavailableView("Your watcher takes shape here", systemImage: "eye", description: Text("The preview updates when the agent saves a draft."))
                        }
                    }.padding(20)
                }.frame(width: 380)
            }
            Divider()
            HStack {
                Text("\(draft?.timezone ?? TimeZone.current.identifier) · Nothing is scheduled until you create it.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
                Spacer()
                Button("Dry run") { Task { await runAction("dry_run") } }.disabled(draft == nil || sending || working)
                Button(draft?.fields["edit_target_id"] == nil ? "Create watcher" : "Apply changes") { Task { await runAction("activate") } }.buttonStyle(.borderedProminent).tint(HerdrTheme.controlAccent).disabled(draft?.state != "draft" || sending || working)
            }.padding(18)
        }.frame(width: 1080, height: 740).herdrPaneBackground()
        .sheet(item: $scriptStep) { step in
            if let draft, let client { WatcherScriptSheet(watcher: draft, step: step, client: client) }
        }
        .sheet(item: $runEntry) { entry in WatcherRunsSheet(store: store, entry: entry, initialRunID: initialRunID) }
        .task(id: draft?.revision) { await previewSchedule() }
        .task(id: sessionID) {
            guard !sessionID.isEmpty else { return }
            while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: working ? .seconds(3) : .seconds(30)) } catch { return } }
        }
    }
    private func send() async {
        guard let client else { return }; sending = true; error = nil
        defer { sending = false }
        do {
            if sessionID.isEmpty {
                var body: [String: PiJSONValue] = ["timezone": .string(TimeZone.current.identifier)]; if let entry { body["watcher_id"] = .string(entry.watcher.id) }
                let response = try await client.watchersMutate(["builder", "sessions"], body: body, requestID: creationRequestID)
                sessionID = response.text("session_id"); guard !sessionID.isEmpty else { throw APIError.invalidResponse }
            }
            _ = try await client.watchersMutate(["builder", "sessions", sessionID, "messages"], body: ["text": .string(prompt)], requestID: pendingRequestID)
            prompt = ""; pendingRequestID = UUID().uuidString; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() async {
        guard let client, !sessionID.isEmpty else { return }
        do { let value = try await client.watchersGet(["builder", "sessions", sessionID]); if !Task.isCancelled { session = value } }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func previewSchedule() async {
        guard let draft, let client else { return }
        do {
            var schedule = draft.schedule; schedule.removeValue(forKey: "summary")
            schedulePreview = try await client.watchersRequest(["schedule", "preview"], method: "POST", body: ["schedule": .object(schedule), "timezone": .string(draft.timezone), "count": .number(3)], query: [])
        } catch { self.error = error.localizedDescription }
    }
    private func setAvatar(_ avatar: String) async {
        guard let draft, draft.state == "draft", let client else { return }; var definition = draft.definition; definition["avatar"] = .string(avatar)
        do { _ = try await client.watchersMutate([draft.id], method: "PATCH", body: ["expected_revision": .number(Double(draft.revision)), "definition": .object(definition)]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    private func runAction(_ action: String) async {
        guard let draft, let client else { return }; sending = true; defer { sending = false }
        do {
            var body: [String: PiJSONValue] = ["action": .string(action)]; if action == "activate" { body["confirmed_by"] = .string("user") }
            if action == "activate" { guard draft.state == "draft" else { return }; body["activated_via"] = .string("mac") }
            let response = try await client.watchersMutate([draft.id, "actions"], body: body, requestID: action == "activate" ? createRequestID : dryRunRequestID)
            await store.refresh()
            if action == "activate" { dismiss() }
            else {
                dryRunRequestID = UUID().uuidString
                initialRunID = response["run"]?.objectValue?.text("id")
                runEntry = .init(machineID: machineID, machineName: machineName, watcher: draft)
                await refresh()
            }
        } catch { self.error = error.localizedDescription }
    }
}
struct WatcherPipeline: View {
    var watcher: Watcher
    var inspectScript: ((WatcherStep) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it runs").font(.system(size: 13, weight: .semibold))
            ForEach(Array(watcher.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.symbol).font(.system(size: 13)).foregroundStyle(HerdrTheme.accent).frame(width: 26, height: 26).background(HerdrTheme.chipFill, in: .rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 5) { Text("\(index + 1). \(step.title)").font(.system(size: 12, weight: .medium)); if !step.file.isEmpty { Button { inspectScript?(step) } label: { Label(step.file, systemImage: "doc.text").font(.system(size: 11, design: .monospaced)) }.buttonStyle(.herdrPlain).foregroundStyle(.mint).disabled(inspectScript == nil) }; if !step.fields.text("note").isEmpty { Text(step.fields.text("note")).font(.caption).foregroundStyle(HerdrTheme.secondaryText) } }
                }
            }
        }
    }
}

struct WatcherScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    var watcher: Watcher
    var step: WatcherStep
    var client: any WatchersClient
    @State private var content: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(step.file, systemImage: "doc.text").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(step.title).font(.system(size: 13))
            Text("\(step.fields.text("interpreter")) · Timeout \(Int(step.fields.number("timeout_seconds"))) seconds").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
            if let content {
                ScrollView([.horizontal, .vertical]) { Text(content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16) }.background(HerdrTheme.codeFill, in: .rect(cornerRadius: 10))
            } else if let error { ContentUnavailableView("Script could not be loaded", systemImage: "exclamationmark.circle", description: Text(error)) }
            else { ProgressView("Loading script…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(24).frame(width: 760, height: 560).herdrPaneBackground()
        .task { do { let value = try await client.watchersGet([watcher.id, "scripts", step.id]); content = value["script"]?.objectValue?.text("content") ?? value.text("content") } catch { self.error = error.localizedDescription } }
    }
}
