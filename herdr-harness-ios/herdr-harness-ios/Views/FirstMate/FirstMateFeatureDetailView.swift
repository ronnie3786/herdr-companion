import SwiftUI

struct FirstMateFeatureDetailView: View {
    @Bindable var store: FirstMateStore
    let featureID: String
    let machineName: String
    let canControl: Bool
    var requestedInspector: FirstMateInspector? = nil
    var inspectorRequestID: UUID? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var showsInspector = false
    @State private var confirmsCancellation = false
    @State private var controlLease = FirstMateWorkspaceControlLease()

    private var snapshot: FirstMateSnapshot? { store.snapshots[featureID] }
    private var featureIsClosed: Bool { ["completed", "cancelled"].contains(snapshot?.feature.status ?? "") }
    private var controlsAvailable: Bool {
        canControl && snapshot != nil && store.selectedFeatureID == featureID
    }
    private var featureActionsAvailable: Bool { controlsAvailable && snapshot?.feature.isLead != true }

    var body: some View {
        Group {
            if let snapshot {
                FirstMateChatView(store: store, snapshot: snapshot, canControl: controlsAvailable, openInspector: openInspector)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Feature couldn't load", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await store.refresh() } }
                }
            } else {
                ProgressView("Opening your feature…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FirstMatePalette(scheme: scheme).background)
        .navigationTitle(snapshot?.feature.title ?? "First Mate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(scheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Feature options", systemImage: "ellipsis.circle") {
                    Button("Feature overview", systemImage: "square.grid.2x2") { openInspector(.overview) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    if store.isDemo {
                        Button("Next demo scenario", systemImage: "forward.end", action: store.advanceDemo)
                            .accessibilityIdentifier("first-mate-demo-next")
                    }
                    Divider()
                    if snapshot?.feature.status == "paused" {
                        Button("Resume feature", systemImage: "play") { perform("resume") }
                            .disabled(!featureActionsAvailable || store.isSending)
                    } else {
                        Button("Pause feature", systemImage: "pause") { perform("pause") }
                            .disabled(!featureActionsAvailable || store.isSending || featureIsClosed)
                    }
                    Button("Cancel feature", systemImage: "stop.circle", role: .destructive) { confirmsCancellation = true }
                        .disabled(!featureActionsAvailable || store.isSending || featureIsClosed)
                }
                .accessibilityIdentifier("first-mate-feature-options")
                .confirmationDialog("Cancel this feature?", isPresented: $confirmsCancellation, titleVisibility: .visible) {
                    Button("Cancel feature", role: .destructive) { perform("cancel") }
                    Button("Keep working", role: .cancel) { }
                } message: {
                    Text("First Mate will stop this feature's work. Its conversation, documents, and saved sessions remain available.")
                }
            }
        }
        .modifier(FirstMateInspectorPresentation(
            store: store, snapshot: snapshot, isPresented: $showsInspector
        ))
        .onChange(of: controlsAvailable, initial: true) { _, available in
            controlLease.update(store: store, available: available)
        }
        .onChange(of: store.lifecycle) { _, _ in
            controlLease.update(store: store, available: controlsAvailable)
        }
        .onDisappear { controlLease.release() }
        .task(id: inspectorRequestID) {
            if let requestedInspector { openInspector(requestedInspector) }
        }
        .task(id: featureID) {
            if store.selectedFeatureID != featureID { store.select(featureID) }
            await store.refresh()
        }
    }

    private func openInspector(_ inspector: FirstMateInspector) {
        store.inspector = inspector
        showsInspector = true
    }

    private func perform(_ action: String) {
        guard featureActionsAvailable, !store.isSending, !featureIsClosed else { return }
        let context = store.operationContext
        Task {
            guard featureActionsAvailable else { return }
            await store.perform(action, expectedContext: context)
        }
    }
}
