import SwiftUI

struct FirstMateCreateSheet: View {
    @Bindable var store: FirstMateStore
    let machineName: String
    let recentFolders: [String]
    let canControl: Bool
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var title = ""
    @State private var goal = ""
    @State private var cwd = ""
    @State private var requestID = UUID().uuidString

    private var canCreate: Bool {
        canControl && !store.isSending && [title, goal, cwd].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
                        .accessibilityLabel("Repository folder on the Mac")
                        .accessibilityIdentifier("first-mate-create-folder")
                } header: { Text("Repository on \(machineName)") } footer: {
                    Text("Work runs on this Mac. Choose the repository First Mate should work in.")
                }
                if let error = store.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                }
                Section {
                    Button(action: create) {
                        HStack {
                            Spacer()
                            if store.isSending { ProgressView() }
                            Text(store.isSending ? "Creating feature…" : "Create feature").fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("first-mate-create-submit")
                }
            }
            .disabled(store.isSending)
            .navigationTitle("New feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(scheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isSending)
                }
            }
            .interactiveDismissDisabled(store.isSending)
            .onChange(of: title) { requestID = UUID().uuidString }
            .onChange(of: goal) { requestID = UUID().uuidString }
            .onChange(of: cwd) { requestID = UUID().uuidString }
        }
        .tint(FirstMatePalette(scheme: scheme).accent)
        .accessibilityIdentifier("first-mate-create-sheet")
    }

    private func create() {
        guard canCreate else { return }
        let context = store.operationContext
        Task {
            if await store.create(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                requestID: requestID,
                expectedContext: context
            ), let id = store.selectedFeatureID {
                dismiss()
                onCreated(id)
            }
        }
    }
}
