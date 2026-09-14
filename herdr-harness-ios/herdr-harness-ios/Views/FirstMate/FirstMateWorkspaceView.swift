import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: FirstMateStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var scheme
    @State private var path: [String] = []

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    featureList
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: {
                    if let id = store.selectedFeatureID {
                        detail(id)
                    } else {
                        ContentUnavailableView("Your feature, in focus", systemImage: "sailboat", description: Text("Choose a feature to talk with its First Mate and follow the work."))
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    featureList
                        .navigationDestination(for: String.self) { id in detail(id) }
                }
            }
        }
        .tint(FirstMatePalette(scheme: scheme).accent)
        .sheet(isPresented: $store.isCreating) {
            FirstMateCreateSheet(
                store: store,
                machineName: model.firstMateMachineName,
                recentFolders: recentFolders,
                canControl: model.firstMateCanControl,
                onCreated: openFeature
            )
        }
        .onChange(of: model.firstMateMachineID) { _, _ in path = [] }
        .onChange(of: model.isDemoMode) { _, _ in path = [] }
        .onChange(of: model.connectionGeneration) { _, _ in path = [] }
        .accessibilityIdentifier("first-mate-workspace")
    }

    private var featureList: some View {
        FirstMateFeatureListView(model: model, store: store, openFeature: openFeature)
    }

    private func detail(_ id: String) -> some View {
        FirstMateFeatureDetailView(
            store: store, featureID: id, machineName: model.firstMateMachineName,
            canControl: model.firstMateCanControl
        )
        .id("\(model.firstMateMachineID)-\(id)")
    }

    private var recentFolders: [String] {
        let workspaces = model.workspaces.filter { $0.machineID == model.firstMateMachineID }
        let folders = workspaces.map { $0.worktree?.repoRoot ?? $0.displayPath } + store.features.map(\.cwd)
        return Array(Set(folders.filter { !$0.isEmpty })).sorted()
    }

    private func openFeature(_ id: String) {
        store.select(id)
        if horizontalSizeClass != .regular { path = [id] }
    }
}
