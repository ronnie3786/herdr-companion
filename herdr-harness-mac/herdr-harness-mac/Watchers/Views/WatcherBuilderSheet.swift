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
    @FocusState private var composerFocused: Bool
    private var client: (any WatchersClient)? { store.client(for: machineID) }
    private var draft: Watcher? { session["draft"]?.objectValue.map(Watcher.init) }
    private var working: Bool { ["running", "working", "starting", "queued"].contains(session.text("status")) }
    private var machineName: String { store.sources.first { $0.machineID == machineID }?.machineName ?? "Companion" }
    private var messages: [[String: PiJSONValue]] { session["messages"]?.arrayValue?.compactMap(\.objectValue) ?? [] }
    init(store: WatchersStore, entry: WatcherEntry?, initialSnapshot: [String: PiJSONValue] = [:]) {
        self.store = store; self.entry = entry; _session = State(initialValue: initialSnapshot)
        _machineID = State(initialValue: entry?.machineID ?? store.sources.first(where: { store.enabledMachines.contains($0.machineID) })?.machineID ?? store.sources.first?.machineID ?? "")
    }
    private var machineOn: Bool { store.state(for: machineID).isOn }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                chat.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(HerdrTheme.hairline).frame(width: 1)
                draftPane.frame(width: 470).frame(maxHeight: .infinity).background(Color.black.opacity(0.12))
            }
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            footer
        }
        .frame(width: 1080, height: 740)
        .watchersSheetChrome()
        .sheet(item: $scriptStep) { step in
            if let draft, let client { WatcherScriptSheet(watcher: draft, step: step, client: client) }
        }
        .sheet(item: $runEntry) { entry in WatcherRunsSheet(store: store, entry: entry, initialRunID: initialRunID) }
        .task(id: draft?.revision) { await previewSchedule() }
        .task(id: sessionID) {
            guard !sessionID.isEmpty else { return }
            while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: working ? .seconds(3) : .seconds(30)) } catch { return } }
        }
        .task { if store.sources.contains(where: { $0.machineID == machineID }) == false { machineID = store.sources.first?.machineID ?? "" } }
    }
    private var header: some View {
        HStack(spacing: 11) {
            FirstMateFaceOrb(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry == nil ? "New watcher" : "Edit watcher").font(.system(size: 15, weight: .semibold))
                Text(entry == nil ? "Your agent on \(machineName) drafts it with you. Nothing runs until you create it." : "Describe what should change. It applies after you save.")
                    .font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("Runs on").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText)
            WatcherMachineMenu(store: store, selection: $machineID).disabled(!sessionID.isEmpty || sending || entry != nil)
            Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                .buttonStyle(HerdrIconButtonStyle(tint: HerdrTheme.secondaryText)).keyboardShortcut(.cancelAction).help("Close")
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 14)
    }
    @ViewBuilder private var chat: some View {
        if !machineOn && sessionID.isEmpty {
            VStack { Spacer(minLength: 0); WatcherMachineSetupPanel(store: store, machineID: machineID); Spacer(minLength: 0) }
                .frame(maxWidth: .infinity).padding(24)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty { intro }
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in bubble(message) }
                        let tools = (session["tools"]?.arrayValue ?? []).compactMap(\.objectValue)
                        if !tools.isEmpty { toolList(tools) }
                        if working || sending {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing your watcher…").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText) }
                        }
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(WatchersStyle.rose).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 6) }
                composer.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
            }
        }
    }
    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What should this watcher do?").font(.system(size: 18, weight: .semibold)).padding(.bottom, 6)
            Text("Say when it runs, what it checks, whether an agent should think about the results, and where they go. Scripts handle the predictable parts; an agent only wakes when it’s needed.")
                .font(.system(size: 12.5)).foregroundStyle(HerdrTheme.proseText).lineSpacing(4).frame(maxWidth: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Check repository health every morning and put a summary in my Watcher inbox.", "Run my maintenance script every night at 1 AM.", "Every 15 minutes, look for pull requests that need my review."], id: \.self) { example in
                    Button { prompt = example } label: {
                        HStack(spacing: 6) { Image(systemName: "sparkles").font(.system(size: 10.5)).foregroundStyle(HerdrTheme.accent); Text(example).lineLimit(1) }
                            .font(.system(size: 11.5)).foregroundStyle(HerdrTheme.proseText)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(HerdrTheme.inkFill(0.05), in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.herdrPlain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.top, 120)
    }
    @ViewBuilder private func bubble(_ message: [String: PiJSONValue]) -> some View {
        let text = message.text("text", fallback: message.text("content"))
        if message.text("role") == "user" {
            HStack { Spacer(minLength: 60); Text(text).font(.system(size: 12.5)).foregroundStyle(HerdrTheme.primaryText).textSelection(.enabled).padding(.vertical, 9).padding(.horizontal, 12)
                .background(HerdrTheme.selectedFill, in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12)) }
        } else {
            HStack(alignment: .top, spacing: 9) {
                FirstMateFaceOrb(size: 22)
                WatcherSummaryView(markup: text, schedule: draft?.scheduleSummary ?? "on your schedule", lineHeight: 1.75).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func toolList(_ tools: [[String: PiJSONValue]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                if index > 0 { Rectangle().fill(HerdrTheme.rowDivider).frame(height: 1) }
                DisclosureGroup {
                    Text(tool.text("output")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(WatchersStyle.hex(0xCFE9DD)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tool.text("status") == "failed" ? "exclamationmark.circle" : "checkmark").font(.system(size: 10.5)).foregroundStyle(tool.text("status") == "failed" ? WatchersStyle.rose : WatchersStyle.mint)
                        Text(tool.text("title", fallback: tool.text("name", fallback: "Working"))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(WatchersStyle.hex(0xD8D5E6)).lineLimit(1)
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
            }
        }
        .background(Color.black.opacity(0.2), in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
        .padding(.leading, 31)
    }
    private var composer: some View {
        let empty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blocked = empty || sending || working || client == nil || !machineOn
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Describe the watcher, or refine this draft…", text: $prompt, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.vertical, 4).focused($composerFocused).onSubmit { if !blocked { Task { await send() } } }
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(blocked ? HerdrTheme.secondaryText : HerdrTheme.onPrimary)
                    .frame(width: 28, height: 28).background(blocked ? HerdrTheme.selectedFill : HerdrTheme.accent, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.herdrPlain).disabled(blocked).help("Send to the watcher builder")
        }
        .padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 8)
        .background(WatchersStyle.hex(0x0E0D13, 0.55), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(composerFocused ? HerdrTheme.accent.opacity(0.6) : HerdrTheme.outline, lineWidth: 1))
    }
    @ViewBuilder private var draftPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let draft {
                    Text(entry == nil ? "Draft" : "Draft changes").font(.system(size: 12, weight: .semibold)).foregroundStyle(HerdrTheme.proseText).padding(.bottom, 10)
                    WatcherCard(entry: .init(machineID: machineID, machineName: machineName, watcher: draft), preview: true).frame(maxWidth: 340).frame(maxWidth: .infinity)
                    HStack(spacing: 6) {
                        Button { Task { await setAvatar((draft.kind == "script" ? WatcherAvatar.instruments : WatcherAvatar.characters).randomElement() ?? draft.avatar) } } label: { Label("Shuffle avatar", systemImage: "shuffle") }
                        Button { showAvatars = true } label: { Label("Choose", systemImage: "square.grid.2x2") }
                    }
                    .buttonStyle(HerdrButtonStyle(kind: .ghost)).disabled(working || sending || draft.state != "draft")
                    .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 22)
                    .popover(isPresented: $showAvatars) { WatcherAvatarPicker(character: draft.kind != "script", selection: Binding(get: { draft.avatar }, set: { value in showAvatars = false; Task { await setAvatar(value) } })) }
                    Text("How it runs").font(.system(size: 12, weight: .semibold)).foregroundStyle(HerdrTheme.proseText).padding(.bottom, 12)
                    WatcherPipeline(watcher: draft, inspectScript: { scriptStep = $0 })
                    let next = (schedulePreview["next"]?.arrayValue ?? []).compactMap { WatchersDate.parse($0.stringValue) }
                    if !next.isEmpty {
                        Text("Next runs").font(.system(size: 12, weight: .semibold)).foregroundStyle(HerdrTheme.proseText).padding(.top, 8).padding(.bottom, 8)
                        ForEach(next, id: \.self) { date in
                            HStack(spacing: 6) { Image(systemName: "clock").font(.system(size: 10.5)).foregroundStyle(WatchersStyle.amber); Text(WatchersDate.display(date, timezone: draft.timezone)).monospacedDigit() }
                                .font(.system(size: 11.5)).foregroundStyle(HerdrTheme.proseText).padding(.bottom, 4)
                        }
                    }
                    Text("Watcher inbox delivery is suppressed during a dry run. Scripts still execute and can contact external services.")
                        .font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                } else {
                    VStack(spacing: 14) {
                        HStack(spacing: 6) { ForEach(["lumen", "gauge", "quill", "cog", "juno"], id: \.self) { WatcherAvatar(avatar: $0, size: 36) } }.opacity(0.6)
                        Text("Your draft shows up here.\nOne of these gets the job.").font(.system(size: 12.5)).foregroundStyle(HerdrTheme.secondaryText).multilineTextAlignment(.center).lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 220)
                }
            }
            .padding(.vertical, 18).padding(.horizontal, 20)
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Text(entry == nil ? "Nothing runs until you create it." : "Changes apply after you save.").font(.system(size: 11.5)).foregroundStyle(HerdrTheme.secondaryText)
            Text("·").foregroundStyle(HerdrTheme.secondaryText)
            Text(draft?.timezone ?? TimeZone.current.identifier).font(.system(size: 11.5)).foregroundStyle(HerdrTheme.secondaryText)
            Spacer()
            Button("Dry run") { Task { await runAction("dry_run") } }.buttonStyle(HerdrButtonStyle(kind: .outline)).disabled(draft == nil || sending || working)
            Button(draft?.fields["edit_target_id"] == nil ? "Create watcher" : "Apply changes") { Task { await runAction("activate") } }
                .buttonStyle(HerdrButtonStyle(kind: .primary)).disabled(draft?.state != "draft" || sending || working)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
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
/// The prototype's "How it runs" list: one node per step on a thin rail.
struct WatcherPipeline: View {
    var watcher: Watcher
    var inspectScript: ((WatcherStep) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(watcher.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    node(step)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(alignment: .top) { if index < watcher.steps.count - 1 { Rectangle().fill(HerdrTheme.outline).frame(width: 1).padding(.top, 30).padding(.bottom, 2) } }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.system(size: 12.5, weight: .semibold)).padding(.top, 4)
                        if !step.file.isEmpty {
                            Button { inspectScript?(step) } label: {
                                HStack(spacing: 6) { Text("Script").foregroundStyle(HerdrTheme.secondaryText); Text(step.file).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(WatchersStyle.hex(0xCFE9DD)) }.font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.herdrPlain).disabled(inspectScript == nil).help("Review \(step.file)")
                        } else if step.kind == "agent" {
                            Text([step.fields.text("display_name"), step.fields.text("skill")].filter { !$0.isEmpty }.joined(separator: " runs ")).font(.system(size: 11, weight: .medium)).foregroundStyle(HerdrTheme.secondaryText)
                        }
                        if !step.fields.text("note").isEmpty { Text(step.fields.text("note")).font(.system(size: 12)).foregroundStyle(HerdrTheme.proseText).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }
    @ViewBuilder private func node(_ step: WatcherStep) -> some View {
        switch step.kind {
        case "agent": WatcherMiniFace(size: 28)
        case "gate":
            RoundedRectangle(cornerRadius: 3).strokeBorder(WatchersStyle.amber, lineWidth: 1.6).frame(width: 12, height: 12).rotationEffect(.degrees(45)).frame(width: 28, height: 28)
        case "script":
            WatcherTerminalGlyph(size: 14).foregroundStyle(WatchersStyle.mint).frame(width: 28, height: 28)
                .background(WatchersStyle.mint.opacity(0.10), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WatchersStyle.mint.opacity(0.32), lineWidth: 1))
        default:
            Image(systemName: "tray").font(.system(size: 12)).foregroundStyle(HerdrTheme.accent).frame(width: 28, height: 28)
                .background(HerdrTheme.chipFill, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HerdrTheme.outline, lineWidth: 1))
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
            HStack { Label(step.file, systemImage: "doc.text").font(.system(size: 15, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.buttonStyle(HerdrButtonStyle(kind: .outline)).keyboardShortcut(.cancelAction) }
            Text(step.title).font(.system(size: 13))
            Text("\(step.fields.text("interpreter")) · Timeout \(Int(step.fields.number("timeout_seconds"))) seconds").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
            if let content {
                ScrollView([.horizontal, .vertical]) { Text(content).font(.system(size: 12, design: .monospaced)).foregroundStyle(WatchersStyle.hex(0xCFE9DD)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16) }.background(Color.black.opacity(0.28), in: .rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
            } else if let error { ContentUnavailableView("Script could not be loaded", systemImage: "exclamationmark.circle", description: Text(error)) }
            else { ProgressView("Loading script…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(24).frame(width: 760, height: 560).watchersSheetChrome()
        .task { do { let value = try await client.watchersGet([watcher.id, "scripts", step.id]); content = value["script"]?.objectValue?.text("content") ?? value.text("content") } catch { self.error = error.localizedDescription } }
    }
}
