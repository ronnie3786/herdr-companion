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
            HStack { Text("Past runs · \(entry.watcher.name)").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if loading { ProgressView() }
                        if !loading && runs.isEmpty { Text(store.demo ? "Demo watchers have no real runs." : "No runs yet.").foregroundStyle(HerdrTheme.secondaryText).padding() }
                        ForEach(runs) { run in
                            Button { selected = run; step = "" } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Circle().fill(run.status == "failed" || run.status == "unknown" ? Color.pink : run.status == "finished" ? Color.mint : HerdrTheme.secondaryText).frame(width: 6, height: 6); Text(run.label).font(.system(size: 12, weight: .semibold)); Spacer(); Text(duration(run)).font(.caption) }
                                    if let date = WatchersDate.parse(run.fields["started_at"]?.stringValue) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(HerdrTheme.secondaryText) }
                                    Text(run.summary).font(.system(size: 12)).foregroundStyle(HerdrTheme.secondaryText).multilineTextAlignment(.leading)
                                }.padding(14).background(selected?.id == run.id ? HerdrTheme.selectedFill : HerdrTheme.cardFill, in: .rect(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }.frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                VStack(alignment: .leading, spacing: 14) {
                    if let selected {
                        Text(selected.label).font(.title3)
                        Text(selected.summary).font(.system(size: 13)).textSelection(.enabled)
                        HStack {
                            Picker("Step", selection: $step) { Text("All steps").tag(""); ForEach(Array(selected.steps.enumerated()), id: \.offset) { _, value in Text(value.text("title", fallback: value.text("step_id"))).tag(value.text("step_id", fallback: value.text("id"))) } }
                            Picker("Stream", selection: $stream) { Text("Output").tag("stdout"); Text("Errors").tag("stderr") }.pickerStyle(.segmented).frame(width: 160)
                        }
                        ScrollView([.horizontal, .vertical]) { Text(logs.isEmpty ? "No output for this step." : logs).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(14) }.background(HerdrTheme.codeFill, in: .rect(cornerRadius: 8))
                    } else { ContentUnavailableView("Choose a run", systemImage: "clock.arrow.circlepath") }
                    if let error { Text(error).foregroundStyle(.pink).font(.caption) }
                }.padding(20).frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(width: 940, height: 650).herdrPaneBackground()
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: runs.contains { ["queued", "running"].contains($0.status) } ? .seconds(5) : .seconds(30)) } catch { return }
                await load()
            }
        }
        .task(id: (selected?.id ?? "") + step + stream) { await loadLogs() }
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
    @State private var error: String?
    private struct Item: Identifiable { let machine: String; let fields: [String: PiJSONValue]; var id: String { machine + ":" + fields.text("id") } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Watcher inbox", systemImage: "tray").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let error { Text(error).foregroundStyle(.pink) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                if items.isEmpty { ContentUnavailableView("All caught up", systemImage: "tray", description: Text("Results and watchers that need you appear here.")) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(item.fields.text("title", fallback: "Watcher update")).font(.headline); Spacer(); Button("Mark read") { Task { await markRead(item) } }.font(.caption) }
                        PiMarkdownMessageView(source: item.fields.text("body_md", fallback: item.fields.text("body", fallback: item.fields.text("summary"))), isStreaming: false, detectsPaneLinks: false)
                    }.padding(18).background(HerdrTheme.cardFill, in: .rect(cornerRadius: 12))
                }
            } }
        }.padding(24).frame(width: 700, height: 600).herdrPaneBackground().task { await load() }
    }
    private func load() async {
        items = []
        for source in store.sources {
            do { let value = try await source.client.watchersGet(["inbox"], query: [.init(name: "unread", value: "1")]); items += (value["items"] ?? value["inbox"])?.arrayValue?.compactMap { $0.objectValue.map { Item(machine: source.machineID, fields: $0) } } ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }
    private func markRead(_ item: Item) async {
        guard let client = store.client(for: item.machine) else { return }
        do { _ = try await client.watchersMutate(["inbox", item.fields.text("id"), "read"]); items.removeAll { $0.id == item.id }; await store.refresh() }
        catch { self.error = error.localizedDescription }
    }
}
