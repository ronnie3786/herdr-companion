import SwiftUI

struct ChatTabColorLabelEditor: View {
    let store: ChatTabColorStore
    let color: ChatTabColor
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(store: ChatTabColorStore, color: ChatTabColor) {
        self.store = store
        self.color = color
        _text = State(initialValue: store.label(for: color))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Color label", text: $text)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("chat-color-label-input-\(color.rawValue)")
                } header: {
                    Text("Label")
                } footer: {
                    Text("Use 1–80 characters on one line. This shared color label is saved only in this app's local sandbox.")
                }

                Section {
                    Button("Reset to \(color.defaultLabel)", systemImage: "arrow.counterclockwise") {
                        store.resetLabel(color)
                        dismiss()
                    }
                    .frame(minHeight: SidebarMetrics.controlHeight)
                }
            }
            .navigationTitle("Rename \(color.defaultLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(ChatTabColorStore.validLabel(text) == nil)
                        .accessibilityIdentifier("chat-color-label-save")
                }
            }
        }
    }

    private func save() {
        guard store.rename(color, to: text) else { return }
        dismiss()
    }
}
