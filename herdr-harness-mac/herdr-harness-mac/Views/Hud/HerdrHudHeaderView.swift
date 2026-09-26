import SwiftUI

struct HerdrHudHeaderView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession
    @State private var showsHistory = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .herdrFont(size: 14)
                .foregroundStyle(HerdrTheme.accent)
                .padding(.trailing, 4)
                .accessibilityHidden(true)
            Text(controller.chats?.selectedChat == nil ? "New HUD chat" : "HUD chat")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.primaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)

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
                    .frame(width: 6, height: 6)
                    .padding(.horizontal, 2)
                    .accessibilityLabel(model.connectionState(forMachine: machineID).title)
            }

            Spacer()

            Button("Chat history", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                .buttonStyle(HerdrIconButtonStyle())
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
                }
                .buttonStyle(HerdrIconButtonStyle())
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("hud-clear-history")
                .help("Leave this chat in its mini HUD and start another")
            }

            Button(action: controller.collapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(HerdrIconButtonStyle())
            .accessibilityLabel("Collapse HUD")
            .accessibilityIdentifier("hud-collapse")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: HerdrTheme.ControlHeight.titleBar)
        .herdrHairline(.bottom)
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
            HerdrHudChip(
                title: selectedMachine?.name ?? "Choose machine",
                tint: selectedMachine == nil ? HerdrTheme.alert : HerdrTheme.secondaryText,
                maxTitleWidth: 120
            )
        }
        .piChipMenu()
        // The machine and folder chips share the header's spare width and
        // truncate together, so the header always fits a 420pt card.
        .fixedSize(horizontal: false, vertical: true)
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

/// MonoCode's `.chip6` for the HUD header menus: 12pt text and a 10pt
/// chevron in a 24pt chip with a 28pt hit area.
struct HerdrHudChip: View {
    var systemImage: String? = nil
    let title: String
    var tint: Color = HerdrTheme.secondaryText
    var maxTitleWidth: CGFloat? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .herdrFont(size: 12)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTitleWidth)
            Image(systemName: "chevron.down")
                .herdrFont(size: HerdrTheme.TextSize.micro, weight: .semibold)
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
        }
        .herdrFont(size: HerdrTheme.TextSize.small)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(minHeight: HerdrTheme.ControlHeight.small)
        .background(isHovered ? HerdrTheme.hoverFill : .clear, in: .rect(cornerRadius: HerdrTheme.Radius.control))
        .frame(minHeight: HerdrTheme.minHitTarget)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
