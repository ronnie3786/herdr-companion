import SwiftUI

struct RemoteNotesView: View {
    @Bindable var model: HerdrAppModel
    @State private var store = RemoteNotesStore()
    @State private var selectedMachineID = ""
    @State private var search = ""
    @State private var path: [String] = []
    @State private var initializedScope = false
    @Environment(\.scenePhase) private var scenePhase

    private var visibleNotes: [RemoteNote] {
        store.visibleNotes(machineID: selectedMachineID, search: search)
    }

    private var visibleMachines: [HerdrMachine] {
        model.machines.filter { selectedMachineID.isEmpty || $0.id == selectedMachineID }
    }

    private var refreshKey: String {
        let active = model.selectedTab == .notes && scenePhase == .active
        return "\(active)|\(model.connectionGeneration)|\(model.machines.map(\.id).joined(separator: ","))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                HerdrBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        header
                        machineMessages
                        if visibleNotes.isEmpty {
                            emptyState
                        } else {
                            ForEach(visibleNotes) { note in
                                NavigationLink(value: note.id) {
                                    RemoteNoteCard(note: note, machineName: machineName(note.machineID))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("notes-card-\(note.id)")
                            }
                        }
                    }
                    .padding(HerdrTheme.pagePadding)
                }
                .refreshable { await refresh() }
            }
            .navigationTitle("Notes")
            .searchable(text: $search, prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh notes", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .disabled(store.isRefreshing)
                    .accessibilityIdentifier("notes-refresh")
                }
            }
            .navigationDestination(for: String.self) { id in
                RemoteNoteDetailView(
                    store: store, noteID: id,
                    machineName: machineName(MachineScopedID.split(id)?.machineID ?? ""),
                    save: { note, title, body in
                        try await model.updateNote(note, title: title, body: body)
                    },
                    refresh: refresh
                )
            }
        }
        .onAppear {
            if !initializedScope {
                if case let .machine(id) = model.machineScope { selectedMachineID = id }
                initializedScope = true
            }
        }
        .onChange(of: model.connectionGeneration) { _, _ in
            store.reset()
            path = []
            if !model.machines.contains(where: { $0.id == selectedMachineID }) { selectedMachineID = "" }
        }
        .task(id: refreshKey) {
            guard model.selectedTab == .notes, scenePhase == .active else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            } while !Task.isCancelled
        }
        .accessibilityIdentifier("notes-view")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Mac HUD notes, on your phone.")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.mist)
            Picker("Notes from", selection: $selectedMachineID) {
                Text("All Macs").tag("")
                ForEach(model.machines) { machine in
                    Text(machine.name).tag(machine.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("notes-machine-picker")
            Text("Edit a note here to sync it back to your Mac. Changes appear automatically while Notes is open.")
                .font(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var machineMessages: some View {
        ForEach(visibleMachines) { machine in
            if let error = store.machineErrors[machine.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Label(machine.name, systemImage: "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.caption)
                    if let refreshed = store.lastRefreshed[machine.id] {
                        Text("Last loaded \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(HerdrTheme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(HerdrTheme.elevated, in: .rect(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isRefreshing, store.lastRefreshed.isEmpty, store.machineErrors.isEmpty {
            ProgressView("Loading notes…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if model.machines.isEmpty {
            ContentUnavailableView("Add a Mac", systemImage: "desktopcomputer", description: Text("Connect a Mac in Settings to see its shared notes."))
        } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: search)
        } else if visibleMachines.contains(where: { store.machineErrors[$0.id] != nil }) {
            ContentUnavailableView("Notes couldn’t load", systemImage: "wifi.exclamationmark", description: Text("Reconnect your Mac and pull down to try again. Previously loaded notes stay available during this visit."))
        } else {
            ContentUnavailableView("No notes yet", systemImage: "note.text", description: Text("Create a note in your Mac HUD, or ask an agent to add one. It will appear here after syncing."))
        }
    }

    private func machineName(_ id: String) -> String {
        model.machines.first(where: { $0.id == id })?.name ?? "Mac"
    }

    private func refresh() async {
        await store.refresh(machineIDs: model.machines.map(\.id)) { machineID in
            try await model.fetchNotes(machineID: machineID)
        }
    }
}
