import SwiftUI

struct PRReviewAgentsView: View {
    @Bindable var store: PRReviewStore
    var openPane: (String, String?) -> Void = { _, _ in }

    private var runs: [PRReviewRun] {
        (store.snapshot?.runs ?? []).sorted {
            ($0.startedAt ?? $0.createdAt ?? "") > ($1.startedAt ?? $1.createdAt ?? "")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HerdrTheme.cardPadding) {
                if runs.isEmpty {
                    ContentUnavailableView("No agent runs", systemImage: "person.2")
                } else {
                    ForEach(runs) { run in
                        PRReviewRunRow(store: store, run: run, openPane: openPane)
                    }
                }
                events
            }
            .padding(HerdrTheme.pagePadding)
        }
        .background(HerdrTheme.graphite)
        .accessibilityIdentifier("pr-review-agents")
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events").herdrFont(.headline)
            ForEach((store.snapshot?.events ?? []).sorted { $0.sequence > $1.sequence }) { event in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(HerdrTheme.accent).frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary).herdrFont(.body)
                        Text("\(event.type) · \(event.createdAt.prefix(10))")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                }
            }
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .accessibilityIdentifier("pr-review-events")
    }
}

private struct PRReviewRunRow: View {
    @Bindable var store: PRReviewStore
    let run: PRReviewRun
    let openPane: (String, String?) -> Void
    @State private var isOutputExpanded = false
    @State private var output: String?
    @State private var outputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.skillTitle).herdrFont(.headline)
                Text(run.state.rawValue.capitalized)
                    .herdrFont(.caption, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.18), in: .capsule)
                Spacer()
                if let paneID = run.paneID {
                    Button("Open pane") { openPane(paneID, store.currentMachineID) }
                }
                if run.state == .running {
                    Button("Finish") { Task { await store.finishRun(run, state: .finished) } }
                    Button("Mark failed") { Task { await store.finishRun(run, state: .failed) } }
                }
            }
            Text(metadata)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            if let note = run.note ?? run.error, !note.isEmpty {
                Text(note).herdrFont(.caption).foregroundStyle(run.error == nil ? HerdrTheme.mist : HerdrTheme.alert)
            }
            DisclosureGroup("Latest output", isExpanded: $isOutputExpanded) {
                Group {
                    if let output {
                        Text(output).herdrFont(.caption, monospaced: true)
                    } else if let outputError {
                        Text(outputError).herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 6)
            }
            .onChange(of: isOutputExpanded) { _, expanded in
                guard expanded, output == nil else { return }
                Task {
                    do { output = try await store.runOutput(runID: run.id) }
                    catch { outputError = error.localizedDescription }
                }
            }
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .accessibilityIdentifier("pr-review-run-\(run.id)")
    }

    private var metadata: String {
        let launch = run.launch ?? "manual"
        let range = [run.startedAt ?? run.createdAt, run.finishedAt].compactMap { $0 }.joined(separator: " → ")
        return [launch, range, run.actor].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private var stateColor: Color {
        switch run.state {
        case .failed: HerdrTheme.alert
        case .finished: HerdrTheme.success
        case .running, .queued: HerdrTheme.working
        case .ended, .unknown: HerdrTheme.muted
        }
    }
}
