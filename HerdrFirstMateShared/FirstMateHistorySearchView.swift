import SwiftUI

struct FirstMateHistorySearchView: View {
    let store: FirstMateStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var records: [FirstMateHistoryRecord] = []
    @State private var nextOffset: Int?
    @State private var error: String?
    @State private var loading = false
    @State private var selected: FirstMateHistoryRecord?
    @State private var lifecycle: FirstMateStore.LifecycleIdentity?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Search requests, outcomes, documents, commits and saved links on this companion host.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal)
                HStack {
                    TextField("Search completed work", text: $query)
                        .onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }.disabled(loading)
                }.padding(.horizontal)
                if loading { ProgressView("Searching…").padding(.horizontal) }
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
                List(records) { record in
                    Button { selected = record } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).font(.headline)
                            Text("\(record.createdAt) · \(record.status)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let nextOffset {
                    Button("Load more records") { Task { await search(offset: nextOffset) } }
                        .disabled(loading).padding(.horizontal)
                }
            }
            .navigationTitle("Completed work")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                lifecycle = store.lifecycle
                if !store.hasLoaded { await store.refresh() }
                await search()
            }
            .onChange(of: store.lifecycle) { _, _ in
                records = []; nextOffset = nil; selected = nil
                error = "The connection changed. Close this screen and open completed work again."
            }
            .sheet(item: $selected) { record in
                FirstMateArchiveReportView(store: store, featureID: record.featureID, archiveID: record.id)
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    private func search(offset: Int = 0) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        if offset == 0 { submittedQuery = query; records = []; nextOffset = nil }
        do {
            guard lifecycle == store.lifecycle else { throw CancellationError() }
            guard store.archiveCleanupSupported else {
                error = "Update this companion to search completed work records."
                return
            }
            let page = try await store.searchHistory(query: submittedQuery, offset: offset)
            guard lifecycle == store.lifecycle else { throw CancellationError() }
            records += page.records
            nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}
