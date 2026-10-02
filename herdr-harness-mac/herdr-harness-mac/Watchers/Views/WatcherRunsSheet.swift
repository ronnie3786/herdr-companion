import SwiftUI

struct WatcherRunsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: WatchersStore
    var entry: WatcherEntry
    var initialRunID: String? = nil
    @State private var runs: [WatcherRun] = []
    @State private var selected: WatcherRun?
    @State private var logs = ""
    @State private var step = ""
    @State private var stream = "stdout"
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WatcherAvatar(avatar: entry.watcher.avatar, resting: entry.watcher.resting, working: entry.watcher.live != nil, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.watcher.name).font(.system(size: 15, weight: .semibold))
                    Text("Past runs on \(entry.machineName)").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(HerdrButtonStyle(kind: .outline)).keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 14).padding(.horizontal, 18)
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                        if !loading && runs.isEmpty { Text(store.demo ? "Demo watchers have no real runs." : "No runs yet. Use Run now to try it.").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).padding(14) }
                        ForEach(runs) { run in
                            Button { selected = run; step = "" } label: { runRow(run) }.buttonStyle(.herdrPlain)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 340)
                Rectangle().fill(HerdrTheme.hairline).frame(width: 1)
                VStack(alignment: .leading, spacing: 14) {
                    if let selected {
                        HStack(spacing: 8) { dot(selected); Text(selected.label).font(.system(size: 15, weight: .semibold)); Spacer(); Text(duration(selected)).font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText).monospacedDigit() }
                        if !selected.summary.isEmpty { Text(selected.summary).font(.system(size: 12.5)).foregroundStyle(HerdrTheme.proseText).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        HStack {
                            Picker("Step", selection: $step) { Text("All steps").tag(""); ForEach(Array(selected.steps.enumerated()), id: \.offset) { _, value in Text(value.text("title", fallback: value.text("step_id"))).tag(value.text("step_id", fallback: value.text("id"))) } }
                                .labelsHidden().frame(maxWidth: 240)
                            Spacer()
                            Picker("Stream", selection: $stream) { Text("Output").tag("stdout"); Text("Errors").tag("stderr") }
                            .pickerStyle(.segmented)
                            .tint(HerdrTheme.controlAccent)
                            .labelsHidden().frame(width: 160)
                        }
                        ScrollView([.horizontal, .vertical]) {
                            Text(logs.isEmpty ? "No output for this step." : logs).font(.system(size: 11, design: .monospaced)).foregroundStyle(logs.isEmpty ? HerdrTheme.secondaryText : WatchersStyle.hex(0xCFE9DD))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                        }
                        .background(Color.black.opacity(0.28), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HerdrTheme.hairline, lineWidth: 1))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(HerdrTheme.secondaryText)
                            Text("Choose a run to see what happened.").font(.system(size: 12.5)).foregroundStyle(HerdrTheme.secondaryText)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(WatchersStyle.rose) }
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 940, height: 650).watchersSheetChrome()
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: runs.contains { ["queued", "running"].contains($0.status) } ? .seconds(5) : .seconds(30)) } catch { return }
                await load()
            }
        }
        .task(id: (selected?.id ?? "") + step + stream) { await loadLogs() }
    }
    private func runRow(_ run: WatcherRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                dot(run)
                Text(run.label).font(WatchersStyle.font(12.5, weight: WatchersStyle.w550))
                Spacer(minLength: 6)
                if let date = WatchersDate.parse(run.fields["started_at"]?.stringValue) { Text(date.formatted(date: .abbreviated, time: .shortened) + ", " + duration(run)).font(.system(size: 11)).foregroundStyle(HerdrTheme.secondaryText).monospacedDigit() }
            }
            if !run.summary.isEmpty { Text(run.summary).font(.system(size: 12)).foregroundStyle(HerdrTheme.proseText).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading) }
        }
        .padding(.vertical, 10).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected?.id == run.id ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: 9))
        .contentShape(Rectangle())
    }
    /// The prototype's run dot: mint finished, hollow nothing new, rose needs attention, gray stopped.
    @ViewBuilder private func dot(_ run: WatcherRun) -> some View {
        switch run.status {
        case "nothing_new": Circle().strokeBorder(HerdrTheme.inkFill(0.4), lineWidth: 1.4).frame(width: 8, height: 8)
        case "failed", "unknown": Circle().fill(WatchersStyle.rose).frame(width: 8, height: 8)
        case "stopped", "queued": Circle().fill(HerdrTheme.secondaryText).frame(width: 8, height: 8)
        default: Circle().fill(WatchersStyle.mint).frame(width: 8, height: 8)
        }
    }
    private func duration(_ run: WatcherRun) -> String { let seconds = Int(run.fields.number("duration_seconds")); return seconds > 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s" }
    private func load() async {
        defer { loading = false }; guard let client = store.client(for: entry.machineID) else { return }
        do { let response = try await client.watchersGet([entry.watcher.id, "runs"], query: [.init(name: "limit", value: "200")]); runs = response["runs"]?.arrayValue?.compactMap { $0.objectValue.map(WatcherRun.init) } ?? []; if selected == nil, let initialRunID { selected = runs.first { $0.id == initialRunID } }; if let id = selected?.id, let updated = runs.first(where: { $0.id == id }) { selected = updated; await loadLogs() } }
        catch { self.error = error.localizedDescription }
    }
    private func loadLogs() async {
        guard let selected, let client = store.client(for: entry.machineID) else { return }; logs = ""
        do {
            let detail = try await client.watchersGet(["runs", selected.id])
            guard !Task.isCancelled else { return }
            if let run = detail["run"]?.objectValue { self.selected = WatcherRun(fields: run) }
            var query = [URLQueryItem(name: "stream", value: stream)]; if !step.isEmpty { query.append(.init(name: "step", value: step)) }
            let response = try await client.watchersGet(["runs", selected.id, "logs"], query: query)
            guard !Task.isCancelled else { return }; logs = String(response.text("content").suffix(131_072))
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
struct WatcherInboxSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: WatchersStore
    @State private var items: [Item] = []
    @State private var failures: [String] = []
    @State private var loading = true
    @State private var history: Item?
    private struct Item: Identifiable {
        let machine: String
        let fields: [String: PiJSONValue]
        var id: String { machine + ":" + fields.text("id") }
        var unread: Bool { fields["read_at"]?.stringValue == nil }
        var date: Date? { WatchersDate.parse(fields["created_at"]?.stringValue) }
    }
    private var unread: Int { items.filter(\.unread).count }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "tray").font(.system(size: 15)).foregroundStyle(HerdrTheme.accent)
                    .frame(width: 34, height: 34).background(HerdrTheme.accent.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watcher inbox").font(.system(size: 15, weight: .semibold))
                    Text(unread > 0 ? "\(unread) unread" : "Results your watchers save for you").font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                if unread > 0 { Button("Mark all read") { Task { await markAllRead() } }.buttonStyle(HerdrButtonStyle(kind: .ghost)) }
                Button("Done") { dismiss() }.buttonStyle(HerdrButtonStyle(kind: .outline)).keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 14).padding(.horizontal, 18)
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(failures, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(WatchersStyle.rose) }
                    if loading && items.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    else if items.isEmpty { empty }
                    ForEach(items) { item in row(item) }
                }
                .padding(18)
            }
        }
        .frame(width: 720, height: 620).watchersSheetChrome()
        .task { await load() }
        .sheet(item: $history) { item in
            if let entry = entry(for: item) { WatcherRunsSheet(store: store, entry: entry, initialRunID: item.fields.text("run_id")) }
        }
    }
    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 24)).foregroundStyle(HerdrTheme.secondaryText)
            Text(store.enabledMachines.isEmpty && !store.demo ? "Turn on Watchers on a computer to get results here." : "Nothing here yet").font(.system(size: 14, weight: .semibold))
            Text("Watchers leave results here when a step saves to your Watcher inbox. Script-only watchers, like ones imported from Cronboard, report on their own; open Past runs on a card to see what they did.")
                .font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
    }
    private func row(_ item: Item) -> some View {
        let entry = entry(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let entry { WatcherAvatar(avatar: entry.watcher.avatar, size: 26) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry?.watcher.name ?? "Watcher").font(.system(size: 11.5, weight: .medium)).foregroundStyle(HerdrTheme.proseText)
                    Text([store.machineName(for: item.machine), item.date.map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer()
                if item.unread { Circle().fill(HerdrTheme.accent).frame(width: 7, height: 7).accessibilityLabel("Unread") }
            }
            Text(item.fields.text("title", fallback: "Watcher update")).font(.system(size: 13.5, weight: .semibold))
            PiMarkdownMessageView(source: item.fields.text("body_md", fallback: item.fields.text("body", fallback: item.fields.text("summary"))), isStreaming: false, detectsPaneLinks: false)
            HStack(spacing: 14) {
                if item.unread { Button { Task { await markRead(item) } } label: { Label("Mark read", systemImage: "checkmark") }.buttonStyle(WatcherActionButtonStyle(emphasized: true)) }
                if entry != nil, !item.fields.text("run_id").isEmpty { Button { history = item } label: { Label("See the run", systemImage: "clock.arrow.circlepath") }.buttonStyle(WatcherActionButtonStyle()) }
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .background(item.unread ? HerdrTheme.accent.opacity(0.05) : HerdrTheme.cardFill, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(item.unread ? HerdrTheme.accent.opacity(0.22) : HerdrTheme.outline, lineWidth: 1))
    }
    private func entry(for item: Item) -> WatcherEntry? { store.entries.first { $0.machineID == item.machine && $0.watcher.id == item.fields.text("watcher_id") } }
    /// Read and unread items from every machine where Watchers is on, newest first.
    private func load() async {
        defer { loading = false }
        var loaded: [Item] = [], failed: [String] = []
        for source in store.sources where store.enabledMachines.contains(source.machineID) {
            do {
                let value = try await source.client.watchersGet(["inbox"], query: [.init(name: "limit", value: "100")])
                loaded += (value["items"] ?? value["inbox"])?.arrayValue?.compactMap { $0.objectValue.map { Item(machine: source.machineID, fields: $0) } } ?? []
            } catch { failed.append("\(source.machineName): \(error.localizedDescription)") }
        }
        items = loaded.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }; failures = failed
    }
    private func markRead(_ item: Item) async {
        guard let client = store.client(for: item.machine) else { return }
        do { _ = try await client.watchersMutate(["inbox", item.fields.text("id"), "read"]); await load(); await store.refresh() }
        catch { failures = [error.localizedDescription] }
    }
    private func markAllRead() async {
        for machine in Set(items.filter(\.unread).map(\.machine)) {
            guard let client = store.client(for: machine) else { continue }
            do { _ = try await client.watchersMutate(["inbox", "read-all"]) } catch { failures.append(error.localizedDescription) }
        }
        await load(); await store.refresh()
    }
}
