import SwiftUI

/// Lives on the list so an updated or reordered card cannot tear down its alert.
struct AgentSessionActionPresentation: ViewModifier {
    @Bindable var model: HerdrAppModel
    @Binding var action: AgentSessionAction?
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: action?.id) {
                renameText = action?.pane.displayTitle ?? ""
            }
            .alert(action?.title ?? "Session actions", isPresented: isPresented, presenting: action) { selected in
                if selected.kind == .rename {
                    TextField("Session name", text: $renameText)
                }
                Button("Cancel", role: .cancel) { }
                Button(selected.buttonTitle, role: selected.kind == .rename ? nil : .destructive) {
                    let label = renameText
                    Task { await perform(selected, label: label) }
                }
                .disabled(!model.canControl(machineID: selected.pane.machineID)
                    || model.paneLifecycleBusyIDs.contains(selected.pane.id)
                    || (selected.kind == .rename && renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            } message: { selected in
                Text(selected.message)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { action != nil }, set: { if !$0 { action = nil } })
    }

    private func perform(_ selected: AgentSessionAction, label: String) async {
        guard model.canControl(machineID: selected.pane.machineID),
              !model.paneLifecycleBusyIDs.contains(selected.pane.id),
              let pane = model.pane(id: selected.pane.id),
              pane.piSemantic?.sessionID == selected.pane.piSemantic?.sessionID else {
            model.toastMessage = "This session changed. Open its actions again."
            return
        }
        switch selected.kind {
        case .rename: await model.rename(pane, label: label)
        case .interrupt: await model.sendKeys(["ctrl+c"], to: pane)
        case .endAndClose: await model.endPiSessionAndClosePane(in: pane)
        case .close: await model.close(pane)
        }
    }
}
