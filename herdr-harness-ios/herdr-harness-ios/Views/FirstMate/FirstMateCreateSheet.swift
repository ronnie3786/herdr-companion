import SwiftUI

/// Creation keeps an explicit destination and freezes the submitted values
/// before scheduling transport. A folder never follows a destination change.
struct FirstMateCreateSheet: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let onCreated: (FirstMateFeatureTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var goal = ""
    @State private var cwd = ""
    @State private var requestID = UUID().uuidString
    @State private var lastDestination: String?
    @State private var isSubmitting = false
    @State private var isVisible = true
    @State private var localError: String?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, goal, folder }

    private var destinationStore: FirstMateStore? { fleet.creationMachineID.flatMap { fleet.store(forMachineID: $0) } }
    private var destinationName: String? { fleet.creationMachineID.map { model.machineName($0) } }
    private var canCreate: Bool {
        guard let machineID = fleet.creationMachineID else { return false }
        return model.firstMateCanControl(machineID: machineID) && destinationStore != nil
            && destinationStore?.isSending != true && !isSubmitting
            && [title, goal, cwd].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var recentFolders: [String] {
        guard let machineID = fleet.creationMachineID else { return [] }
        let workspaces = model.workspaces.filter { $0.machineID == machineID }
        let folders = workspaces.map { $0.worktree?.repoRoot ?? $0.displayPath }
            + (fleet.store(forMachineID: machineID)?.features.map(\.cwd) ?? [])
        return Array(Set(folders.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A First Mate for this feature", systemImage: "sailboat.fill")
                            .herdrFont(.headline).foregroundStyle(HerdrTheme.accent)
                        Text("Shape a plan together. First Mate delegates the work, keeps the evidence, and checks with you between stages.")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.proseText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).herdrCard()

                    VStack(alignment: .leading, spacing: 12) {
                        HerdrMicroLabel(text: "Destination machine")
                        Menu {
                            Button("Choose a machine") { destinationBinding.wrappedValue = nil }
                            ForEach(fleet.hosts) { host in
                                Button(host.machineName) { destinationBinding.wrappedValue = host.machineID }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(destinationName ?? "Choose a machine")
                                    .herdrFont(.body).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                            }
                            .foregroundStyle(HerdrTheme.primaryText)
                            .padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .herdrField().contentShape(.rect)
                        }
                        .accessibilityLabel("Create on, \(destinationName ?? "Choose a machine")")
                        .accessibilityIdentifier("first-mate-create-machine")
                        .composerLayoutMeasurement(id: "create-destination-control")
                        Text("The feature, its agents and its records stay on the chosen Mac.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }
                    .padding(16).herdrCard()

                    VStack(alignment: .leading, spacing: 12) {
                        HerdrMicroLabel(text: "The outcome")
                        TextField("", text: $title, prompt: Text("Feature or idea").foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                            .focused($focusedField, equals: .title)
                            .lineLimit(1...3).padding(12).herdrField()
                            .accessibilityIdentifier("first-mate-create-title")
                        TextField("", text: $goal, prompt: Text("What would success look like?").foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                            .focused($focusedField, equals: .goal)
                            .lineLimit(3...7).padding(12).herdrField()
                            .accessibilityIdentifier("first-mate-create-goal")
                    }
                    .herdrFont(.body).foregroundStyle(HerdrTheme.primaryText)
                    .padding(16).herdrCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(destinationName.map { "Repository on \($0)" } ?? "Repository")
                            .herdrFont(.footnote, weight: .semibold).foregroundStyle(HerdrTheme.secondaryText)
                        if !recentFolders.isEmpty {
                            Menu("Choose a recent folder", systemImage: "folder") {
                                ForEach(recentFolders, id: \.self) { folder in Button(folder) { cwd = folder } }
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("first-mate-create-recent-folders")
                        }
                        TextField("", text: $cwd, prompt: Text("/path/to/repository").foregroundStyle(HerdrTheme.tertiaryText), axis: .vertical)
                            .focused($focusedField, equals: .folder)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .lineLimit(1...3).padding(12).herdrField()
                            .disabled(fleet.creationMachineID == nil)
                            .accessibilityLabel(destinationName.map { "Repository folder on \($0)" } ?? "Repository folder on the chosen Mac")
                            .accessibilityIdentifier("first-mate-create-folder")
                        Text("Work runs on the chosen Mac. Choose the repository First Mate should work in.")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    }
                    .herdrFont(.body).foregroundStyle(HerdrTheme.primaryText)
                    .padding(16).herdrCard()

                    if let error = localError ?? destinationStore?.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .herdrFont(.body).foregroundStyle(HerdrTheme.warning)
                    }
                    Button(isSubmitting ? "Creating feature…" : "Create feature", action: create)
                        .buttonStyle(HerdrButtonStyle(kind: .primary))
                        .disabled(!canCreate)
                        .accessibilityIdentifier("first-mate-create-submit")
                        .composerLayoutMeasurement(id: "create-submit-control")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSubmitting || destinationStore?.isSending == true)
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
            .navigationTitle("New feature").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSubmitting) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Next field") {
                        focusedField = focusedField == .title ? .goal : focusedField == .goal ? .folder : nil
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    Button("Done") { focusedField = nil }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("first-mate-create-keyboard-done")
                }
            }
            .onChange(of: title) { requestID = UUID().uuidString }
            .onChange(of: goal) { requestID = UUID().uuidString }
            .onChange(of: cwd) { requestID = UUID().uuidString }
            .onChange(of: fleet.creationMachineID, initial: true) { _, destination in
                if lastDestination != destination { clearDestinationFolder(destination) }
            }
            .onChange(of: destinationStore?.lifecycle) { _, _ in clearDestinationFolder(fleet.creationMachineID) }
        }
        .herdrFirstMateChrome()
        .tint(HerdrTheme.accent)
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-create-sheet")
    }

    private var destinationBinding: Binding<String?> {
        Binding(get: { fleet.creationMachineID }, set: { destination in
            guard destination != fleet.creationMachineID else { return }
            clearDestinationFolder(destination)
            fleet.creationMachineID = destination
        })
    }
    private func clearDestinationFolder(_ destination: String?) {
        cwd = ""
        lastDestination = destination
        requestID = UUID().uuidString
    }
    private func create() {
        guard canCreate, let machineID = fleet.creationMachineID, let store = destinationStore else { return }
        let context = store.operationContext
        let submittedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedID = requestID
        let intent = model.beginAppNavigation()
        isSubmitting = true
        localError = nil
        Task {
            let target = await fleet.create(on: machineID, title: submittedTitle, goal: submittedGoal, cwd: submittedCWD,
                                            requestID: submittedID, expectedContext: context)
            guard isVisible else { return }
            isSubmitting = false
            guard fleet.isCreating, fleet.creationMachineID == machineID, fleet.store(forMachineID: machineID) === store,
                  store.lifecycle == context.lifecycleIdentity, fleet.chat.isCurrentNavigation(intent) else { return }
            if let target {
                fleet.isCreating = false
                dismiss()
                onCreated(target)
            } else { localError = store.error ?? "The feature could not be created on its chosen machine." }
        }
    }
}
