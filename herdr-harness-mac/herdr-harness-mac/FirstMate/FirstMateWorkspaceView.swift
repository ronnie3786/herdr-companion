import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var store: FirstMateStore
    let canControl: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                HSplitView {
                    FirstMateChatView(store: store, snapshot: snapshot, canControl: canControl)
                        .frame(minWidth: 330, idealWidth: 480, maxWidth: .infinity)
                    FirstMateInspectorView(store: store, snapshot: snapshot)
                        .frame(minWidth: 340, idealWidth: 465, maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView {
                    Label(store.unsupported ? "First Mate needs a server update" : "A First Mate for every feature", systemImage: "sailboat")
                } description: {
                    Text(store.error ?? "Start with a ticket or an idea. Keep the plan, independent agents, and evidence in one conversation.")
                } actions: {
                    if !store.unsupported {
                        Button("New feature") { store.isCreating = true }.disabled(!canControl)
                    }
                    Button("Refresh") { Task { await store.refresh() } }
                }
            }
        }
        .background(FirstMatePalette(scheme: scheme).background)
        .foregroundStyle(.primary)
        .tint(FirstMatePalette(scheme: scheme).accent)
        .task(id: store.selectedFeatureID) { await observe() }
        .sheet(isPresented: $store.isCreating) { FirstMateCreateSheet(store: store) }
        .sheet(item: $store.resourcePresentation, onDismiss: store.closeResource) { _ in
            if let resource = store.openedResource {
                FirstMateResourceSheet(store: store, resource: resource)
                    .id(resource.id)
            }
        }
        .accessibilityIdentifier("first-mate-workspace")
    }

    private func observe() async {
        repeat {
            await store.refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        } while !Task.isCancelled && !store.isDemo && !store.unsupported
    }
}
