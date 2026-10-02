import SwiftUI

struct FirstMateConversationsBar: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Binding var showsSearch: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPad names the list beside the host picker and keeps search open
    /// under the bar, so the pill holds only New and More.
    private var regular: Bool { horizontalSizeClass == .regular }
    #if DEBUG
    @State private var showsDiagnostics = false
    @State private var diagnostics = ""
    #endif

    /// "7 features · 3 need you", as the prototype's list header reads.
    private var summary: String {
        let features = FirstMateMobileListPresentation(fleet: fleet).rows.count
        let needs = fleet.conversations.count { $0.hudStatus.needsYou }
        let count = "\(features) \(features == 1 ? "feature" : "features")"
        return needs == 0 ? count : "\(count) · \(needs) \(needs == 1 ? "needs" : "need") you"
    }

    var body: some View {
        HStack(spacing: regular ? 8 : 12) {
            FirstMateMachinePicker(model: model, fleet: fleet)
            if regular {
                VStack(alignment: .leading, spacing: 1) {
                    Text("First Mates").herdrFont(.headline, weight: .bold).foregroundStyle(HerdrTheme.primaryText)
                    Text(summary).herdrFont(size: 12.5, relativeTo: .caption).foregroundStyle(HerdrTheme.tertiaryText)
                }
                .lineLimit(1).minimumScaleFactor(0.9)
                // Takes the row's slack itself: a spacer would add two more gaps.
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("first-mate-list-title")
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                if !regular {
                    Button {
                        showsSearch.toggle()
                        if !showsSearch { fleet.search = "" }
                    } label: {
                        Label("Search conversations", systemImage: showsSearch ? "xmark" : "magnifyingglass")
                            .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .accessibilityIdentifier("first-mate-chat-search-toggle")
                    .composerLayoutMeasurement(id: "conversation-search-control")
                }
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
            .padding(.horizontal, 4)
            .herdrControlGlass(in: .capsule)
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(HerdrTheme.primaryText)
        .buttonStyle(.herdrPlain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-chat-bar")
        #if DEBUG
        .alert("List diagnostics", isPresented: $showsDiagnostics) {
            Button("OK", role: .cancel) { }
        } message: { Text(diagnostics) }
        #endif
    }
}

/// The companion host menu: All Machines or one machine.
struct FirstMateMachinePicker: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore

    var body: some View {
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
                .labelStyle(.iconOnly).herdrGlassCircle(44)
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(HerdrTheme.primaryText)
        .disabled(model.machines.isEmpty)
        .accessibilityLabel("Companion host, \(model.firstMateScopeLabel)")
        .accessibilityIdentifier("first-mate-machine-picker")
        .composerLayoutMeasurement(id: "conversation-host-control")
    }
}
