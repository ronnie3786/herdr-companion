import SwiftUI

struct FirstMateProjectArchiveSheet: View {
    @State private var model: FirstMateProjectArchiveModel
    @State private var candidate: FirstMateFeature?
    @State private var showCleanup = false
    @State private var isArchiving = false
    @State private var error: String?
    let archiveProject: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    init(model: FirstMateProjectArchiveModel, archiveProject: @escaping () async -> Bool) {
        _model = State(initialValue: model)
        self.archiveProject = archiveProject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Archive project", systemImage: "archivebox").herdrFont(size: 22, weight: .semibold)
            Text(model.project.name).foregroundStyle(HerdrTheme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Project folder and session history stay available", systemImage: "lock")
                                .font(.headline)
                            Text(model.project.cwd).font(.callout.monospaced()).textSelection(.enabled)
                            Text("Archiving hides this saved project from new-session choices. Its source folder and existing sessions stay in place. Active work continues.")
                            Text("Restore from Projects → Show archived.")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .background(HerdrTheme.cardFill, in: .rect(cornerRadius: 10))
                    Toggle("Review completed sessions for cleanup", isOn: $showCleanup)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("first-mate-project-review-cleanup")
                    Text("Choose resources to delete in each session before archiving the project.")
                        .font(.callout).foregroundStyle(.secondary)
                    if showCleanup {
                        if model.isLoading { ProgressView("Loading this project’s sessions…") }
                        if !model.supportsReview && model.hasLoaded {
                            Text("Update this companion to review and confirm session cleanup. Project-only archive is still available.")
                        } else if model.completedSessions.isEmpty && model.hasLoaded {
                            Label("No unarchived completed sessions to clean up", systemImage: "checkmark.circle")
                        } else {
                            ForEach(model.completedSessions) { feature in
                                HStack {
                                    Text(feature.title).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Review cleanup…") { candidate = feature }
                                        .disabled(!model.supportsReview || !model.connectionIsCurrent)
                                }
                                Divider()
                            }
                        }
                        if model.hasLoaded {
                            Text("\(model.retainedCount) active or already archived sessions remain as they are.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let error = model.error {
                            Text(error).foregroundStyle(.red)
                            Button("Reload sessions") { Task { await model.load() } }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            Divider()
            HStack {
                if isArchiving { ProgressView("Archiving project…").controlSize(.small) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("0 bytes").herdrFont(size: 18, weight: .semibold)
                        Text("Project-only archive").herdrFont(size: 11).foregroundStyle(HerdrTheme.secondaryText)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isArchiving)
                    .buttonStyle(HerdrButtonStyle(kind: .ghost))
                Button("Archive project, keep remaining resources") { Task { await archive() } }
                    .buttonStyle(HerdrButtonStyle(kind: .primary))
                    .disabled(isArchiving || !model.connectionIsCurrent)
                    .accessibilityIdentifier("first-mate-project-confirm-archive")
            }
        }
        .padding(24)
        .herdrFont(size: 13)
        .foregroundStyle(HerdrTheme.text)
        .modifier(FirstMateArchiveSurface())
        .tint(HerdrTheme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 600, idealWidth: 680, maxWidth: 820, minHeight: 460, idealHeight: 580, maxHeight: 850)
        .interactiveDismissDisabled(isArchiving)
        .task { await model.load() }
        .sheet(item: $candidate, onDismiss: { Task { await model.load() } }) { feature in
            FirstMateArchiveReviewSheet(store: model.sessionStore, model: model.archiveModel(for: feature))
        }
    }

    private func archive() async {
        isArchiving = true
        error = nil
        defer { isArchiving = false }
        guard model.connectionIsCurrent else {
            error = "The connection changed. Close this screen and open the project again."
            return
        }
        if await archiveProject() { dismiss() }
        else { error = "The project could not be archived. Close this screen to inspect the editor’s error and reload if needed." }
    }
}
