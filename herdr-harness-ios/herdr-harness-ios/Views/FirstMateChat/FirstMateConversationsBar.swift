import SwiftUI

struct FirstMateConversationsBar: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Binding var showsSearch: Bool
    #if DEBUG
    @State private var showsDiagnostics = false
    @State private var diagnostics = ""
    #endif

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button { model.selectFirstMateScope(.all) } label: {
                    Label("All Machines", systemImage: fleet.resolvedScope == .all ? "checkmark" : "desktopcomputer")
                }
                .accessibilityIdentifier("first-mate-machine-all")
                Divider()
                ForEach(model.machines) { machine in
                    Button { model.selectFirstMateScope(.machine(machine.id)) } label: {
                        Label(machine.name, systemImage: fleet.resolvedScope == .machine(machine.id) ? "checkmark" : "desktopcomputer")
                    }
                    .accessibilityIdentifier("first-mate-machine-\(machine.id)")
                }
            } label: {
                Label("Companion host", systemImage: "desktopcomputer")
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .background { HerdrGlassBackground(level: 0.80, cornerRadius: 22) }
                    .overlay { Circle().strokeBorder(HerdrTheme.hairline, lineWidth: 1) }
            }
            .disabled(model.machines.isEmpty)
            .accessibilityLabel("Companion host, \(model.firstMateScopeLabel)")
            .accessibilityIdentifier("first-mate-machine-picker")
            .composerLayoutMeasurement(id: "conversation-host-control")

            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button {
                    showsSearch.toggle()
                    if !showsSearch { fleet.search = "" }
                } label: {
                    Label("Search conversations", systemImage: showsSearch ? "xmark" : "magnifyingglass")
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityIdentifier("first-mate-chat-search-toggle")
                .composerLayoutMeasurement(id: "conversation-search-control")
                Button {
                    model.beginAppNavigation()
                    fleet.beginCreating()
                } label: {
                    Label("New feature", systemImage: "plus").labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(.rect)
                }
                .disabled(!model.firstMateCanControlVisibleHosts)
                .accessibilityIdentifier("first-mate-new-feature")
                .composerLayoutMeasurement(id: "conversation-create-control")
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await fleet.refreshAll() } }
                    Button(fleet.showArchived ? "Hide archived" : "Show archived", systemImage: "archivebox") {
                        fleet.setShowArchived(!fleet.showArchived)
                        Task { await fleet.refreshAll() }
                    }
                    .disabled(!fleet.canShowArchived)
                    .accessibilityIdentifier("first-mate-show-archived")
                    #if DEBUG
                    if FirstMateListPerformanceProbe.enabled {
                        Button("List diagnostics") {
                            diagnostics = FirstMateListPerformanceProbe.summary
                            showsDiagnostics = true
                        }
                        .accessibilityIdentifier("first-mate-list-diagnostics")
                    }
                    #endif
                    if fleet.isDemo {
                        Button("Next scenario", systemImage: "forward.end") {
                            fleet.advanceDemo()
                            Task { await fleet.refreshAll() }
                        }
                        .accessibilityIdentifier("first-mate-demo-next")
                    }
                } label: {
                    Label("Conversation options", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("first-mate-options")
                .composerLayoutMeasurement(id: "conversation-more-control")
            }
            .background { HerdrGlassBackground(level: 0.80, cornerRadius: 22) }
            .overlay { Capsule().strokeBorder(HerdrTheme.hairline, lineWidth: 1) }
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(HerdrTheme.iconTint)
        .buttonStyle(.herdrPlain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-chat-bar")
        #if DEBUG
        .alert("List diagnostics", isPresented: $showsDiagnostics) {
            Button("OK", role: .cancel) { }
        } message: { Text(diagnostics) }
        #endif
    }
}
