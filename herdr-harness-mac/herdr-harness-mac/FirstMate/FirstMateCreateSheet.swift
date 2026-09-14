import SwiftUI

struct FirstMateCreateSheet: View {
    @Bindable var store: FirstMateStore
    @State private var title = ""
    @State private var goal = ""
    @State private var cwd = ""
    @State private var requestID = UUID().uuidString
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Start a feature", systemImage: "sailboat").herdrFont(.title2, weight: .semibold)
            Text("Give this work an outcome. Your First Mate will help plan and delegate it, then wait for your direction between stages.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Feature", text: $title).accessibilityIdentifier("first-mate-create-title")
                TextField("Goal", text: $goal, axis: .vertical).lineLimit(3...5)
                TextField("Repository folder on the host", text: $cwd)
            }.textFieldStyle(.roundedBorder)
            if let error = store.error { Text(error).herdrFont(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create feature", action: create).buttonStyle(.borderedProminent)
                    .disabled(store.isSending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("first-mate-create-submit")
            }
        }
        .padding(28).frame(width: 540)
        .onChange(of: title) { requestID = UUID().uuidString }
        .onChange(of: goal) { requestID = UUID().uuidString }
        .onChange(of: cwd) { requestID = UUID().uuidString }
    }
    private func create() {
        Task {
            if await store.create(title: title, goal: goal, cwd: cwd, requestID: requestID) { dismiss() }
        }
    }
}
