import SwiftUI

struct PRReviewRunRow: View {
    @Bindable var store: PRReviewStore
    let run: PRReviewRun
    var canControl = false
    let openPane: (String, String?) -> Void
    @State private var isOutputExpanded = false
    @State private var output: String?
    @State private var outputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.displayName).herdrFont(.headline)
                Text(run.state.rawValue.capitalized)
                    .herdrFont(.caption, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.18), in: .capsule)
                Spacer()
                if let paneID = run.paneID {
                    Button("Open pane") { openPane(paneID, store.currentMachineID) }
                }
                if run.state == .running && run.agentID == nil && !run.isConsolidator {
                    Button("Finish") { Task { await store.finishRun(run, state: .finished) } }.disabled(!canControl)
                    Button("Mark failed") { Task { await store.finishRun(run, state: .failed) } }.disabled(!canControl)
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
        .herdrCard()
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
