import SwiftUI

struct ChatColorLegendRow: View {
    static let rowHeight: CGFloat = 56 * 0.9
    static let titleSize: CGFloat = 14

    let model: HerdrAppModel
    let color: ChatTabColor
    let isSelected: Bool
    let select: () -> Void
    @State private var isEditing = false
    @State private var text = ""

    private var store: ChatTabColorStore { model.chatTabColors }
    private var isNaming: Bool { store.smartRenaming.contains(color) }
    private var canSmartRename: Bool {
        model.workspaces.contains { workspace in
            workspace.panes.contains {
                store.color(for: $0.scopedTabID) == color
                    && $0.piSemantic?.sessionID != nil && model.canControl(machineID: $0.machineID)
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: color.symbol)
                .foregroundStyle(color.swatch)
                .accessibilityHidden(true)
            if isEditing {
                ChatColorLabelEditor(
                    text: $text,
                    identifier: "chat-color-label-input-\(color.rawValue)",
                    finish: { finish(cancel: $0) }
                )
                .background(InlineTitleClickAway { finish() })
            } else {
                Button(action: select) {
                    HStack(spacing: 4) {
                        Text(store.label(for: color))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: Self.rowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(store.label(for: color)) · \(color.defaultLabel)\nClick to filter; click again to show all colors. Use the pencil to edit, or right-click for Smart Rename.")
                .accessibilityLabel("Filter by \(store.label(for: color)), \(color.defaultLabel)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityIdentifier("chat-color-label-\(color.rawValue)")

                Button("Rename color label", systemImage: "pencil", action: edit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.mist)
                    .frame(width: HerdrTheme.minHitTarget, height: Self.rowHeight)
                    .contentShape(.rect)
                    .help("Edit \(store.label(for: color)) inline")
                    .accessibilityIdentifier("chat-color-rename-\(color.rawValue)")
            }
            if isNaming {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Naming \(color.defaultLabel)")
            }
        }
        .herdrFont(size: Self.titleSize, weight: .medium)
        .foregroundStyle(HerdrTheme.text)
        .padding(.horizontal, 8)
        .frame(minHeight: Self.rowHeight)
        .background(color.rowBackground(selected: isSelected), in: .rect(cornerRadius: 6))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.swatch.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { finish() }
        .contextMenu {
            Button("Rename label", systemImage: "pencil", action: edit)
            Button(isNaming ? "Renaming…" : "Smart Rename", systemImage: "sparkles") {
                Task { await model.smartRenameChatColor(color) }
            }
            .disabled(isNaming || !canSmartRename || isEditing)
            Button("Reset label to \(color.defaultLabel)", systemImage: "arrow.counterclockwise") {
                finish(cancel: true)
                store.resetLabel(color)
            }
        }
    }

    private func edit() {
        guard !isEditing else { return }
        text = store.label(for: color)
        // Reserve this label immediately so an AI result cannot overwrite an
        // in-progress manual edit, even if the user later presses Escape.
        store.rename(color, to: text)
        isEditing = true
    }

    private func finish(cancel: Bool = false) {
        guard isEditing else { return }
        isEditing = false
        if !cancel, !store.rename(color, to: text) {
            model.toastMessage = "Label unchanged. Use 1–80 characters on one line."
        }
    }
}
