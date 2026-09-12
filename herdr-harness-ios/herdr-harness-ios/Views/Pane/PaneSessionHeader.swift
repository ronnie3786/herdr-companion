import SwiftUI

struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @Bindable var store: PiConversationStore

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    renameText = pane.displayTitle
                    isRenaming = true
                } label: {
                    Text(pane.displayTitle)
                        .font(.title2.bold())
                        .foregroundStyle(HerdrTheme.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!model.canControl(machineID: pane.machineID))
                .accessibilityLabel("Chat title: \(pane.displayTitle)")
                .accessibilityHint("Renames this pane")
                .accessibilityIdentifier("pane-session-title")

                Button(
                    isStarred ? "Unstar chat" : "Star chat",
                    systemImage: isStarred ? "star.fill" : "star",
                    action: toggleStar
                )
                .labelStyle(.iconOnly)
                .font(.headline)
                .foregroundStyle(isStarred ? HerdrTheme.mauve : HerdrTheme.mist)
                .frame(width: 44, height: 44)
                .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isStarred ? "Starred" : "Not starred")
                .accessibilityIdentifier("pane-session-star")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    agentAndStatus
                    Spacer(minLength: 8)
                    scopeLabel(lineLimit: 1)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 6) {
                    agentAndStatus
                    scopeLabel(lineLimit: 3)
                }
            }
        }
        .alert("Rename pane", isPresented: $isRenaming) {
            TextField("Pane name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save", action: renamePane)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This label is shared with Herdr on your Mac.")
        }
        .onChange(of: pane.id) {
            isRenaming = false
            renameText = ""
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-session-header")
    }

    private var agentAndStatus: some View {
        HStack(spacing: 8) {
            Label(pane.displayAgentName, systemImage: pane.agentStatus == .unknown ? "terminal" : "cpu")
                .foregroundStyle(HerdrTheme.mist)

            Label(statusTitle, systemImage: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityIdentifier("pane-session-status")
        }
        .font(.subheadline)
    }

    private func scopeLabel(lineLimit: Int) -> some View {
        Label(scopeText, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            .font(.footnote)
            .foregroundStyle(HerdrTheme.mist)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Location: \(scopeText)")
            .accessibilityIdentifier("pane-session-scope")
    }

    private var isStarred: Bool {
        model.starredChatIDs.contains(pane.id)
    }

    private var statusTitle: String {
        store.compactionActivity?.statusMessage ?? pane.agentStatus.title
    }

    private var statusSymbol: String {
        store.compactionActivity == nil ? pane.agentStatus.symbol : "arrow.trianglehead.2.clockwise.rotate.90"
    }

    private var statusColor: Color {
        store.compactionActivity == nil ? pane.agentStatus.labelColor : HerdrTheme.working
    }

    private var scopeText: String {
        var components = [machineName]
        if let workspace {
            components.append(workspace.label)
            if let tabName {
                components.append(tabName)
            }
        }
        return components.joined(separator: " → ")
    }

    private var machineName: String {
        model.machines.first(where: { $0.id == pane.machineID })?.name ?? pane.machineID
    }

    private var workspace: HerdrWorkspace? {
        model.workspace(containing: pane)
    }

    private var tabName: String? {
        guard let workspace else { return nil }
        return workspace.tabs.first(where: { $0.id == pane.scopedTabID })?.label
            ?? workspace.tabs.first(where: { $0.tabID == pane.tabID })?.label
    }

    private func toggleStar() {
        model.toggleStarredChat(pane.id)
    }

    private func renamePane() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != pane.displayTitle else { return }
        Task { await model.rename(pane, label: title) }
    }
}
