import SwiftUI

struct HerdrHudHeaderView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession
    @State private var showsHistory = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityHidden(true)
            Text(controller.chats?.selectedChat == nil ? "New HUD chat" : "HUD chat")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)

            if !model.machines.isEmpty {
                machineMenu(selectedMachine)
                    .disabled(session.isLoadingHistory || !session.exchanges.isEmpty || session.isRunning)
            }

            if let selectedMachine {
                HerdrHudWorkingFolderPicker(session: session, machine: selectedMachine)
            }

            if let machineID = selectedMachine?.id {
                Circle()
                    .fill(model.connectionState(forMachine: machineID).color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(model.connectionState(forMachine: machineID).title)
            }

            Spacer()

            Button("Chat history", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .herdrHitTarget()
                .help("Search saved HUD chats")
                .accessibilityIdentifier("hud-chat-history")
                .popover(isPresented: $showsHistory) {
                    if let machineID = selectedMachine?.id {
                        HerdrHudHistoryView(model: model, session: session, machineID: machineID, controller: controller)
                            .id(machineID)
                    }
                }

            if !session.exchanges.isEmpty {
                // Switching composers leaves this conversation and its draft intact.
                Button(action: startNewChat) {
                    Image(systemName: "square.and.pencil")
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("hud-clear-history")
                .help("Leave this chat in its mini HUD and start another")
            }

            Button(action: controller.collapse) {
                Image(systemName: "chevron.up")
                    .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(HerdrTheme.mist)
            .accessibilityLabel("Collapse HUD")
            .accessibilityIdentifier("hud-collapse")
        }
        .padding(.horizontal, HerdrTheme.cardPadding)
        .padding(.vertical, 12)
        .background(
            HerdrHudWindowDragHandle(
                onDragBegan: controller.beginPanelDrag,
                onDragEnded: controller.endPanelDrag
            )
        )
    }

    @ViewBuilder
    private func machineMenu(_ selectedMachine: HerdrMachine?) -> some View {
        Menu {
            ForEach(model.machines) { machine in
                Button {
                    session.selectedMachineID = machine.id
                } label: {
                    if machine.id == selectedMachine?.id {
                        Label(machine.name, systemImage: "checkmark")
                    } else {
                        Text(machine.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedMachine?.name ?? "Choose machine")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .herdrFont(.caption2, weight: .bold)
            }
            .herdrFont(.caption)
            .foregroundStyle(selectedMachine == nil ? HerdrTheme.alert : HerdrTheme.mist)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(selectedMachine.map { "HUD machine: \($0.name)" } ?? "HUD machine: choose a machine")
        .accessibilityIdentifier("hud-machine-picker")
    }

    /// Never falls back to roster order: an unidentified fresh composer asks
    /// for an explicit machine, while an existing conversation resolves its
    /// own machine from its durable identity.
    private var selectedMachine: HerdrMachine? {
        session.selectedMachine(in: model)
    }

    private func startNewChat() {
        controller.summon()
    }
}
