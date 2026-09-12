import SwiftUI

struct ChatTabColorFilterSheet: View {
    let store: ChatTabColorStore
    let activeColors: [ChatTabColor]
    let paneCounts: [ChatTabColor: Int]
    @Binding var selection: ChatTabColor?
    @Environment(\.dismiss) private var dismiss
    @State private var editingColor: ChatTabColor?

    var body: some View {
        NavigationStack {
            List {
                Section("Filter chats") {
                    Button {
                        selection = nil
                    } label: {
                        filterLabel(
                            title: "All colors",
                            detail: "Colored and uncolored chats",
                            systemImage: "line.3.horizontal.decrease.circle",
                            isSelected: selection == nil
                        )
                    }
                    .accessibilityIdentifier("chat-color-filter-all")

                    ForEach(filterColors) { color in
                        Button {
                            selection = color
                        } label: {
                            filterLabel(
                                title: store.label(for: color),
                                detail: "\(paneCounts[color, default: 0]) chats · \(color.defaultLabel)",
                                systemImage: color.symbol,
                                tint: color.swatch,
                                isSelected: selection == color
                            )
                        }
                        .listRowBackground(color.rowBackground(selected: selection == color))
                        .accessibilityIdentifier("chat-color-filter-\(color.rawValue)")
                    }

                    if activeColors.isEmpty {
                        Text("No visible tabs have a color yet. Assign one from a tab, chat, or pane action menu.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(ChatTabColor.allCases) { color in
                        Button {
                            editingColor = color
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: color.symbol)
                                    .foregroundStyle(color.swatch)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.label(for: color))
                                        .foregroundStyle(.primary)
                                    Text(color.defaultLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: SidebarMetrics.controlHeight)
                        }
                        .accessibilityLabel("Edit \(store.label(for: color)), \(color.defaultLabel) color label")
                        .accessibilityIdentifier("chat-color-label-edit-\(color.rawValue)")
                    }
                } header: {
                    Text("Color labels")
                } footer: {
                    Text("Colors and labels are saved only on this iPhone or iPad. Mac assignments are not imported or synchronized.")
                }
            }
            .navigationTitle("Tab colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("chat-color-filter-sheet")
        .sheet(item: $editingColor) { color in
            ChatTabColorLabelEditor(store: store, color: color)
        }
    }

    private var filterColors: [ChatTabColor] {
        ChatTabColor.allCases.filter { activeColors.contains($0) || selection == $0 }
    }

    private func filterLabel(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color = HerdrTheme.mist,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: SidebarMetrics.controlHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
