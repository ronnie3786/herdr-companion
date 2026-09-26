import SwiftUI

/// Creates one feature on exactly one chosen host.
///
/// From All Machines the destination starts unset, so the person must choose a
/// host before a repository folder is accepted. A single-machine scope
/// preselects its host. Changing the destination clears the folder and rotates
/// the idempotency key, so a retry of the same payload still reuses its request.
struct FirstMateCreateSheet: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let onCreated: (FirstMateFeatureTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var title = ""
    @State private var goal = ""
    @State private var cwd = ""
    @State private var requestID = UUID().uuidString

    private var destinationStore: FirstMateStore? {
        fleet.creationMachineID.flatMap { fleet.store(forMachineID: $0) }
    }

    private var destinationName: String? {
        fleet.creationMachineID.map { model.machineName($0) }
    }

    private var canControlDestination: Bool {
        guard let machineID = fleet.creationMachineID else { return false }
        return model.firstMateCanControl(machineID: machineID)
    }

    private var canCreate: Bool {
        destinationStore != nil
            && canControlDestination
            && destinationStore?.isSending != true
            && [title, goal, cwd].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Recent folders come only from the chosen destination: its workspaces and
    /// the repositories its own features already use.
    private var recentFolders: [String] {
        guard let machineID = fleet.creationMachineID else { return [] }
        let workspaces = model.workspaces.filter { $0.machineID == machineID }
        let folders = workspaces.map { $0.worktree?.repoRoot ?? $0.displayPath }
            + (fleet.store(forMachineID: machineID)?.features.map(\.cwd) ?? [])
        return Array(Set(folders.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A First Mate for this feature", systemImage: "sailboat.fill")
                        .font(.headline)
                        .foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                    Text("Shape a plan together. First Mate delegates the work, keeps the evidence, and checks with you between stages.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Create on", selection: destinationBinding) {
                        Text("Choose a machine").tag(String?.none)
                        ForEach(fleet.hosts) { host in
                            Text(host.machineName).tag(String?.some(host.machineID))
                        }
                    }
                    .accessibilityIdentifier("first-mate-create-machine")
                } header: {
                    Text("Destination machine")
                } footer: {
                    Text("The feature, its agents, and its records stay on the chosen Mac.")
                }
                Section("The outcome") {
                    TextField("Feature or idea", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("first-mate-create-title")
                    TextField("What would success look like?", text: $goal, axis: .vertical)
                        .lineLimit(3...7)
                        .accessibilityIdentifier("first-mate-create-goal")
                }
                Section {
                    if !recentFolders.isEmpty {
                        Menu("Choose a recent folder", systemImage: "folder") {
                            ForEach(recentFolders, id: \.self) { folder in
                                Button(folder) { cwd = folder }
                            }
                        }
                        .accessibilityIdentifier("first-mate-create-recent-folders")
                    }
                    TextField("/path/to/repository", text: $cwd, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...3)
                        .accessibilityLabel(destinationName.map { "Repository folder on \($0)" } ?? "Repository folder on the chosen Mac")
                        .accessibilityIdentifier("first-mate-create-folder")
                } header: {
                    if let destinationName {
                        Text("Repository on \(destinationName)")
                    } else {
                        Text("Repository")
                    }
                } footer: {
                    Text("Work runs on the chosen Mac. Choose the repository First Mate should work in.")
                }
                if let error = destinationStore?.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(action: create) {
                        HStack {
                            Spacer()
                            if destinationStore?.isSending == true { ProgressView() }
                            Text(destinationStore?.isSending == true ? "Creating feature…" : "Create feature").fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("first-mate-create-submit")
                }
            }
            .disabled(destinationStore?.isSending == true)
            .navigationTitle("New feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(scheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(destinationStore?.isSending == true)
                }
            }
            .interactiveDismissDisabled(destinationStore?.isSending == true)
            .onChange(of: title) { requestID = UUID().uuidString }
            .onChange(of: goal) { requestID = UUID().uuidString }
            .onChange(of: cwd) { requestID = UUID().uuidString }
            .onChange(of: fleet.creationMachineID) { _, _ in
                // A folder selection belongs to one host. Never carry it, or the
                // request identity of the old host, to a different machine.
                cwd = ""
                requestID = UUID().uuidString
            }
        }
        .tint(FirstMatePalette(scheme: scheme).accent)
        .accessibilityIdentifier("first-mate-create-sheet")
    }

    private var destinationBinding: Binding<String?> {
        Binding(
            get: { fleet.creationMachineID },
            set: { newValue in
                guard newValue != fleet.creationMachineID else { return }
                fleet.creationMachineID = newValue
            }
        )
    }

    private func create() {
        guard canCreate,
              let machineID = fleet.creationMachineID,
              let store = destinationStore else { return }
        let context = store.operationContext
        Task {
            if let target = await fleet.create(
                on: machineID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                requestID: requestID,
                expectedContext: context
            ) {
                fleet.isCreating = false
                dismiss()
                onCreated(target)
            }
        }
    }
}
